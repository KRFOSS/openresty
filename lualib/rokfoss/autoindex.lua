-- ROKFOSS-Shield 자체 오토인덱스
--
-- 설계 요지
--   * 디렉터리 읽기는 nginx 내장 autoindex(autoindex_format json)에 맡긴다.
--     Lua 로 직접 opendir/readdir 하지 않으므로 새로 만드는 위험이 없다.
--   * 결과 JSON 은 shared dict 에 캐싱한다. 미러 디렉터리는 자주 안 바뀌는데
--     fancyindex 는 매 요청마다 디렉터리 전체를 읽어 I/O 를 낭비했다.
--   * 브라우저에는 행 HTML 을 보내지 않는다. 데이터(JSON)만 보내고 화면에
--     보이는 만큼만 그린다. 7천 개 디렉터리에서 DOM 행 7천 개를 만들던
--     기존 방식이 멈춤의 원인이었다.
--   * CSS/JS 는 별도 URL 로 빼서 브라우저가 한 번만 받게 한다. 디렉터리를
--     옮겨 다녀도 다시 받지 않는다.

local _M = { _VERSION = "1.0" }

local assets = require "rokfoss.autoindex_assets"

local ngx = ngx
local concat = table.concat
local byte = string.byte
local sub = string.sub
local format = string.format

-- 내부 서브리퀘스트 접두사. nginx 설정의 internal location 과 맞춘다.
local JSON_PREFIX = "/@rokfoss-index"

-- 캐시. lua_shared_dict rokfoss_index 가 없으면 캐시 없이 동작한다.
local cache = ngx.shared.rokfoss_index
local CACHE_TTL = 30


-- HTML 특수문자 이스케이프.
-- 파일명은 서버가 신뢰할 수 없는 입력이다(업로드/동기화로 들어옴).
-- 데이터는 JSON 으로 나가지만 제목/경로는 HTML 에 직접 박히므로 반드시 막는다.
local HTML_ESCAPES = {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
}

local function escape_html(s)
    if not s then
        return ""
    end
    return (string.gsub(s, "[&<>\"']", HTML_ESCAPES))
end
_M.escape_html = escape_html


-- JSON 문자열을 <script> 안에 안전하게 넣기.
--
-- JSON 자체는 nginx 가 ngx_escape_json 으로 만들어 문법은 정상이지만,
-- 파일명에 "</script>" 가 들어 있으면 브라우저 HTML 파서가 스크립트를
-- 거기서 끊어버린다(JSON 문법과 무관하게 XSS 가 된다).
-- 파일명은 미러 동기화로 들어오는 값이라 이 방어가 반드시 필요하다.
local function shield_json_for_script(json)
    -- </script, <!--, <script 를 무해한 유니코드 이스케이프로 바꾼다.
    -- JSON 문자열 안에서 < 는 '<' 와 동일하게 파싱되므로 데이터는 보존된다.
    json = string.gsub(json, "<", "\\u003c")
    json = string.gsub(json, ">", "\\u003e")
    json = string.gsub(json, "\226\128\168", "\\u2028")  -- LINE SEPARATOR
    json = string.gsub(json, "\226\128\169", "\\u2029")  -- PARAGRAPH SEPARATOR
    return json
end
_M.shield_json_for_script = shield_json_for_script


-- URI 경로를 표시용 조각으로 나눈다(빵부스러기).
local function breadcrumbs(uri)
    local parts = {}
    local acc = ""

    for seg in string.gmatch(uri, "[^/]+") do
        acc = acc .. "/" .. seg
        parts[#parts + 1] = { name = seg, href = acc .. "/" }
    end

    return parts
end
_M.breadcrumbs = breadcrumbs


-- 서브리퀘스트에 넘길 경로를 다시 인코딩한다.
-- ngx.var.uri 는 디코딩된 값이라 공백이나 한글, '%' 가 그대로 들어있다.
-- 그대로 capture 에 넘기면 경로가 깨지거나 엉뚱한 곳을 가리킬 수 있다.
local function encode_path(uri)
    local out = {}
    local i = 0

    for seg in string.gmatch(uri, "[^/]+") do
        i = i + 1
        out[i] = ngx.escape_uri(seg, 0)
    end

    if i == 0 then
        return "/"
    end

    return "/" .. concat(out, "/") .. "/"
end
_M.encode_path = encode_path


-- 디렉터리 목록 JSON 을 얻는다. 캐시 우선.
local function fetch_listing(uri)
    local key = uri

    if cache then
        local hit = cache:get(key)
        if hit then
            return hit, true
        end
    end

    local res = ngx.location.capture(JSON_PREFIX .. encode_path(uri))

    if not res or res.status ~= ngx.HTTP_OK then
        return nil, false, res and res.status or 500
    end

    local body = res.body or "[]"

    if cache then
        -- 캐시가 가득 차도 서비스는 계속되어야 하므로 실패를 무시한다.
        cache:set(key, body, CACHE_TTL)
    end

    return body, false
end


-- 헤더/푸터 조각 캐시.
-- 사이트 브랜딩(상단 바, 하단 링크)을 그대로 쓰되 매 요청마다 파일을 읽지
-- 않는다. fancyindex 는 디렉터리마다 17KB+26KB 를 다시 읽어 붙였다.
local snippet_cache = {}
local SNIPPET_TTL = 60

local function read_snippet(path)
    if not path or path == "" then
        return nil
    end

    local now = ngx.now()
    local hit = snippet_cache[path]

    if hit and hit.expires > now then
        return hit.body
    end

    local fh = io.open(path, "r")
    if not fh then
        -- 조각이 없다고 목록까지 실패시키지는 않는다.
        snippet_cache[path] = { body = nil, expires = now + SNIPPET_TTL }
        return nil
    end

    local body = fh:read("*a")
    fh:close()

    snippet_cache[path] = { body = body, expires = now + SNIPPET_TTL }
    return body
end
_M.read_snippet = read_snippet


-- 디렉터리 페이지를 출력한다.
-- opts.header / opts.footer 로 사이트 공통 조각을 끼울 수 있다.
function _M.run(opts)
    opts = opts or {}
    local uri = ngx.var.uri

    -- 디렉터리가 아니면 우리 일이 아니다.
    -- (403 에서 넘어오는 경로라 원래 상태를 그대로 돌려준다)
    if sub(uri, -1) ~= "/" then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local body, cached, err_status = fetch_listing(uri)

    if not body then
        return ngx.exit(err_status or ngx.HTTP_NOT_FOUND)
    end

    local title = escape_html(uri)
    local crumbs = breadcrumbs(uri)

    local out = {}
    local n = 0

    local function put(s)
        n = n + 1
        out[n] = s
    end

    put([[<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>]])
    put(title)
    put([[ · ROKFOSS Mirror</title>
<link rel="stylesheet" href="]])
    put(assets.CSS_URL)
    put([[">
</head>
<body>
]])

    -- 사이트 공통 상단(있으면). 인증서 배지 같은 건 이 조각에서 뺀다.
    local head_html = read_snippet(opts.header)
    if head_html then
        put(head_html)
    end

    put([[<header class="idx-top">
<div class="idx-brand"><span class="idx-shield">ROKFOSS</span> Mirror</div>
<nav class="idx-crumbs" aria-label="경로"><a href="/">/</a>]])

    for i = 1, #crumbs do
        put('<span class="idx-sep">/</span><a href="')
        put(escape_html(crumbs[i].href))
        put('">')
        put(escape_html(crumbs[i].name))
        put("</a>")
    end

    put([[</nav>
</header>
<main class="idx-main">
<div class="idx-toolbar">
<input type="search" id="idx-search" class="idx-search" placeholder="이 디렉터리에서 검색 (파일명 입력)" autocomplete="off" spellcheck="false" aria-label="파일 검색">
<div class="idx-stats" id="idx-stats" role="status" aria-live="polite"></div>
</div>
<div class="idx-head" role="row">
<button class="idx-h idx-h-name" data-sort="name" type="button">이름</button>
<button class="idx-h idx-h-size" data-sort="size" type="button">크기</button>
<button class="idx-h idx-h-date" data-sort="mtime" type="button">수정일</button>
</div>
<div class="idx-viewport" id="idx-viewport" tabindex="0">
<div class="idx-spacer" id="idx-spacer"></div>
<div class="idx-rows" id="idx-rows"></div>
</div>
<div class="idx-empty" id="idx-empty" hidden>검색 결과가 없습니다.</div>
</main>
<script id="idx-data" type="application/json">]])

    put(shield_json_for_script(body))

    put([[</script>
<script src="]])
    put(assets.JS_URL)
    put([["></script>
]])

    -- 사이트 공통 하단(있으면).
    local foot_html = read_snippet(opts.footer)
    if foot_html then
        put(foot_html)
    end

    put([[</body>
</html>
]])

    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    -- 목록은 자주 바뀌지 않지만 오래 캐시하면 곤란하다. 짧게 준다.
    ngx.header["Cache-Control"] = "public, max-age=30"
    ngx.header["X-ROKFOSS-Index"] = cached and "hit" or "miss"

    ngx.print(out)
end


-- CSS/JS 를 내보낸다. 내용이 바뀌면 URL 도 바뀌므로 영구 캐시해도 안전하다.
function _M.asset(kind)
    local payload, ctype

    if kind == "css" then
        payload, ctype = assets.CSS, "text/css; charset=utf-8"
    else
        payload, ctype = assets.JS, "application/javascript; charset=utf-8"
    end

    ngx.header["Content-Type"] = ctype
    ngx.header["Cache-Control"] = "public, max-age=31536000, immutable"
    ngx.print(payload)
end


return _M
