-- ROKFOSS-Shield 오토인덱스 정적 자산
--
-- CSS/JS 를 Lua 문자열로 들고 있다가 전용 URL 로 서빙한다. 파일을 따로
-- 배치할 필요가 없어 배포가 단순하고, 브라우저는 한 번만 받아 캐시한다.
-- URL 에 버전을 박아두므로 내용이 바뀌면 자동으로 새로 받는다.

local _M = {}

_M.VERSION = "1"

_M.CSS_URL = "/@rokfoss-asset/idx-" .. _M.VERSION .. ".css"
_M.JS_URL  = "/@rokfoss-asset/idx-" .. _M.VERSION .. ".js"


_M.CSS = [[
:root{
  --bg:#1a1a1a; --panel:#212121; --line:#2f2f2f; --text:#e5e5e5;
  --muted:#9a9a9a; --accent:#06b6d4; --dir:#7dd3fc; --hover:#262626;
}
@media (prefers-color-scheme: light){
  :root{--bg:#fafafa;--panel:#fff;--line:#e3e3e3;--text:#1b1b1b;
        --muted:#666;--accent:#0891b2;--dir:#0369a1;--hover:#f1f5f9}
}
*{box-sizing:border-box}
html,body{margin:0;padding:0;height:100%}
body{
  background:var(--bg);color:var(--text);
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Noto Sans KR",sans-serif;
  display:flex;flex-direction:column;
}
a{color:inherit;text-decoration:none}
a:hover{text-decoration:underline}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}

.idx-top{padding:14px 20px;border-bottom:1px solid var(--line);background:var(--panel)}
.idx-brand{font-size:14px;font-weight:700;letter-spacing:.02em;margin-bottom:6px}
.idx-shield{color:var(--accent)}
.idx-crumbs{font-size:13px;color:var(--muted);word-break:break-all}
.idx-crumbs a{color:var(--muted)}
.idx-crumbs a:last-child{color:var(--text);font-weight:600}
.idx-sep{opacity:.4;margin:0 2px}

.idx-main{flex:1;display:flex;flex-direction:column;min-height:0;padding:14px 20px 0}
.idx-toolbar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
.idx-search{
  flex:1;min-width:220px;padding:9px 12px;border-radius:8px;
  border:1px solid var(--line);background:var(--panel);color:var(--text);font-size:14px;
}
.idx-search::placeholder{color:var(--muted)}
.idx-stats{font-size:13px;color:var(--muted);white-space:nowrap}

.idx-head{display:flex;border-bottom:1px solid var(--line);padding:0 4px}
.idx-h{
  background:none;border:0;color:var(--muted);font:inherit;font-size:12px;
  font-weight:600;letter-spacing:.04em;padding:8px 6px;cursor:pointer;text-align:left;
}
.idx-h:hover{color:var(--text)}
.idx-h[aria-sort]{color:var(--accent)}
.idx-h-name{flex:1;min-width:0}
.idx-h-size{width:110px;flex:none;text-align:right}
.idx-h-date{width:190px;flex:none}
@media(max-width:640px){.idx-h-date{display:none}.idx-h-size{width:86px}}

/* 가상 스크롤 뷰포트: 여기 안에서만 스크롤되고, 보이는 행만 그린다 */
.idx-viewport{flex:1;overflow-y:auto;position:relative;min-height:0}
.idx-spacer{width:1px}
.idx-rows{position:absolute;top:0;left:0;right:0}

.idx-row{display:flex;align-items:center;padding:0 4px;border-bottom:1px solid var(--line);height:34px}
.idx-row:hover{background:var(--hover)}
.idx-name{flex:1;min-width:0;display:flex;align-items:center;gap:8px;
          white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:14px}
.idx-name a{overflow:hidden;text-overflow:ellipsis}
.idx-ico{width:16px;flex:none;text-align:center;opacity:.75;font-size:13px}
.idx-dir .idx-name a{color:var(--dir);font-weight:600}
.idx-size{width:110px;flex:none;text-align:right;font-size:13px;color:var(--muted);
          font-variant-numeric:tabular-nums;padding-right:8px}
.idx-date{width:190px;flex:none;font-size:13px;color:var(--muted);font-variant-numeric:tabular-nums}
@media(max-width:640px){.idx-date{display:none}.idx-size{width:86px}}
.idx-hit{background:rgba(6,182,212,.22);border-radius:3px}

.idx-empty{padding:40px 0;text-align:center;color:var(--muted);font-size:14px}
]]


_M.JS = [[
(function(){
"use strict";

var ROW_H = 34;          // .idx-row 높이와 일치해야 한다
var OVERSCAN = 8;        // 화면 밖 여유 행

var raw = document.getElementById("idx-data").textContent;
var all;
try { all = JSON.parse(raw); } catch (e) { all = []; }

var viewport = document.getElementById("idx-viewport");
var spacer   = document.getElementById("idx-spacer");
var rowsBox  = document.getElementById("idx-rows");
var stats    = document.getElementById("idx-stats");
var empty    = document.getElementById("idx-empty");
var search   = document.getElementById("idx-search");

// ── 데이터 정규화 ────────────────────────────────────────────────
// nginx autoindex json: {name, type:"directory"|"file"|"other", mtime, size}
var items = [];
for (var i = 0; i < all.length; i++) {
  var e = all[i];
  var dir = e.type === "directory";
  var t = Date.parse(e.mtime);
  items.push({
    name: e.name,
    lower: e.name.toLowerCase(),
    dir: dir,
    size: dir ? -1 : (typeof e.size === "number" ? e.size : -1),
    time: isNaN(t) ? 0 : t
  });
}

function fmtSize(n){
  if (n < 0) return "-";
  if (n < 1024) return n + " B";
  var u = ["KB","MB","GB","TB"], i = -1, v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
  return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + u[i];
}

function fmtDate(ms){
  if (!ms) return "";
  var d = new Date(ms), p = function(x){ return x < 10 ? "0" + x : x; };
  return d.getFullYear() + "-" + p(d.getMonth()+1) + "-" + p(d.getDate())
         + " " + p(d.getHours()) + ":" + p(d.getMinutes());
}

function icon(it){
  if (it.dir) return "\u{1F4C1}";
  var n = it.lower, dot = n.lastIndexOf("."), ext = dot < 0 ? "" : n.slice(dot+1);
  if (ext === "iso" || ext === "img") return "\u{1F4BF}";
  if (ext === "deb" || ext === "rpm" || ext === "pkg" || ext === "apk") return "\u{1F4E6}";
  if (ext === "gz"||ext==="xz"||ext==="zst"||ext==="bz2"||ext==="zip"||ext==="tar"||ext==="7z") return "\u{1F5DC}";
  if (ext === "asc"||ext==="sig"||ext==="gpg"||ext==="sha256"||ext==="sha512") return "\u{1F511}";
  if (n.indexOf("readme") >= 0 || ext === "txt" || ext === "md") return "\u{1F4C4}";
  return "\u{1F4C4}";
}

// ── 정렬 ────────────────────────────────────────────────────────
var sortKey = "name", sortAsc = true;

function cmp(a, b){
  // 디렉터리를 항상 위로 둔다 — 미러 탐색에서 이게 훨씬 편하다
  if (a.dir !== b.dir) return a.dir ? -1 : 1;
  var r = 0;
  if (sortKey === "size") r = a.size - b.size;
  else if (sortKey === "mtime") r = a.time - b.time;
  else r = a.lower < b.lower ? -1 : (a.lower > b.lower ? 1 : 0);
  return sortAsc ? r : -r;
}

// ── 검색 ────────────────────────────────────────────────────────
// 7천 개 정도는 단순 부분일치로 충분히 즉각적이다.
var view = items.slice().sort(cmp);
var query = "";

function applyFilter(){
  if (!query) {
    view = items.slice().sort(cmp);
  } else {
    var q = query.toLowerCase(), out = [];
    for (var i = 0; i < items.length; i++) {
      if (items[i].lower.indexOf(q) >= 0) out.push(items[i]);
    }
    view = out.sort(cmp);
  }
  viewport.scrollTop = 0;
  layout();
  render();
}

function layout(){
  spacer.style.height = (view.length * ROW_H) + "px";
  stats.textContent = query
    ? view.length.toLocaleString() + " / " + items.length.toLocaleString() + "개"
    : items.length.toLocaleString() + "개 항목";
  empty.hidden = view.length > 0;
}

// ── 가상 렌더링 ─────────────────────────────────────────────────
// 핵심: 화면에 보이는 ~30행만 DOM 에 만든다. 항목이 7천 개든 10만 개든
// DOM 노드 수는 일정하므로 브라우저가 멈추지 않는다.
var lastStart = -1, lastEnd = -1;

function render(force){
  var top = viewport.scrollTop;
  var h = viewport.clientHeight || 600;
  var start = Math.max(0, Math.floor(top / ROW_H) - OVERSCAN);
  var end = Math.min(view.length, Math.ceil((top + h) / ROW_H) + OVERSCAN);

  if (!force && start === lastStart && end === lastEnd) return;
  lastStart = start; lastEnd = end;

  var html = [];
  for (var i = start; i < end; i++) {
    var it = view[i];
    var href = encodeURIComponent(it.name) + (it.dir ? "/" : "");
    html.push(
      '<div class="idx-row', it.dir ? ' idx-dir' : '', '" role="row">',
        '<div class="idx-name"><span class="idx-ico">', icon(it), '</span>',
          '<a href="', href, '" title="', esc(it.name), '">', mark(it.name), '</a>',
        '</div>',
        '<div class="idx-size">', fmtSize(it.size), '</div>',
        '<div class="idx-date">', fmtDate(it.time), '</div>',
      '</div>'
    );
  }

  rowsBox.style.transform = "translateY(" + (start * ROW_H) + "px)";
  rowsBox.innerHTML = html.join("");
}

function esc(s){
  return s.replace(/[&<>"']/g, function(c){
    return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];
  });
}

// 검색어와 일치하는 부분을 강조한다.
function mark(name){
  if (!query) return esc(name);
  var i = name.toLowerCase().indexOf(query.toLowerCase());
  if (i < 0) return esc(name);
  return esc(name.slice(0, i))
       + '<span class="idx-hit">' + esc(name.slice(i, i + query.length)) + '</span>'
       + esc(name.slice(i + query.length));
}

// ── 이벤트 ──────────────────────────────────────────────────────
var ticking = false;
viewport.addEventListener("scroll", function(){
  if (ticking) return;
  ticking = true;
  requestAnimationFrame(function(){ render(); ticking = false; });
}, { passive: true });

window.addEventListener("resize", function(){ render(true); });

var timer = null;
search.addEventListener("input", function(){
  clearTimeout(timer);
  timer = setTimeout(function(){
    query = search.value.trim();
    applyFilter();
  }, 90);
});

// '/' 로 검색창에 바로 진입
document.addEventListener("keydown", function(e){
  if (e.key === "/" && document.activeElement !== search) {
    e.preventDefault();
    search.focus();
    search.select();
  } else if (e.key === "Escape" && document.activeElement === search) {
    search.value = ""; query = ""; applyFilter(); search.blur();
  }
});

var heads = document.querySelectorAll(".idx-h");
for (var k = 0; k < heads.length; k++) {
  (function(btn){
    btn.addEventListener("click", function(){
      var key = btn.getAttribute("data-sort");
      if (sortKey === key) { sortAsc = !sortAsc; }
      else { sortKey = key; sortAsc = true; }
      for (var j = 0; j < heads.length; j++) heads[j].removeAttribute("aria-sort");
      btn.setAttribute("aria-sort", sortAsc ? "ascending" : "descending");
      applyFilter();
    });
  })(heads[k]);
}

layout();
render(true);
})();
]]


return _M
