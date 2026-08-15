# ROKFOSS-Shield 오토인덱스

fancyindex 를 대체하는 자체 디렉터리 목록 기능이다. 미러처럼 항목이 수천
개인 디렉터리에서 브라우저가 멈추지 않게 하는 것이 목표다.

## 왜 만들었나

기존 구성은 fancyindex 가 만든 표를 푸터의 자바스크립트가 다시 훑어
재구성하는 방식이었다. 항목이 7,000 개인 디렉터리에서 이런 일이 벌어진다.

1. 서버가 7,000 행짜리 HTML 표를 만들어 보낸다.
2. 브라우저가 7,000 행을 DOM 으로 만들고 화면 배치까지 계산한다.
3. 그제서야 스크립트가 그 7,000 행을 전부 다시 읽어 배열로 바꾼다.
4. 원래 표를 지우고 처음부터 다시 그린다.

같은 일을 두 번 하고, 화면에 보이지도 않을 행을 실제로 그린다. 여기에
헤더 17KB + 푸터 26KB 가 모든 디렉터리마다 따라붙었다.

## 어떻게 바꿨나

- **디렉터리 읽기는 nginx 내장 autoindex(`autoindex_format json`)에 맡긴다.**
  Lua 로 직접 디렉터리를 훑지 않으므로 새로 만드는 위험이 없다.
- **목록을 캐싱한다.** 미러 디렉터리는 자주 바뀌지 않는데 기존에는 매 요청마다
  디렉터리 전체를 읽었다.
- **행 HTML 을 보내지 않는다.** 데이터(JSON)만 보내고 화면에 보이는 약 30 행만
  그린다. 항목이 7,000 개든 10 만 개든 DOM 노드 수가 일정하다.
- **CSS/JS 를 별도 URL 로 뺀다.** 브라우저가 한 번만 받고, 디렉터리를 옮겨
  다녀도 다시 받지 않는다.

## 기능

- 즉시 검색 (`/` 키로 검색창 진입, `Esc` 로 해제, 일치 부분 강조)
- 이름·크기·수정일 정렬 (디렉터리는 항상 위)
- 경로 빵부스러기, 파일 종류 아이콘
- 다크/라이트 자동 전환, 모바일 대응
- 인증서 배지 없음

## 설정

`lua_shared_dict` 와 내부 location 두 개가 필요하다.

```nginx
http {
    lua_package_path "/usr/local/openresty/lualib/?.lua;;";

    # 목록 캐시. 없어도 동작하지만 있으면 디스크 I/O 가 크게 준다.
    lua_shared_dict rokfoss_index 32m;

    server {
        listen 80;
        root /path/to/mirror;

        location / {
            # 디렉터리에 색인 파일이 없으면 nginx 가 403 을 낸다.
            # 그 403 을 우리 핸들러로 넘긴다.
            error_page 403 = @rokfoss_index;
        }

        location @rokfoss_index {
            content_by_lua_block {
                require("rokfoss.autoindex").run()
            }
        }

        # 내부 전용: 디렉터리 목록을 JSON 으로 뽑는다.
        location /@rokfoss-index/ {
            internal;
            alias /path/to/mirror/;
            autoindex on;
            autoindex_format json;
        }

        # CSS/JS. 내용이 바뀌면 URL 도 바뀌므로 영구 캐시해도 안전하다.
        location ~ ^/@rokfoss-asset/idx-\d+\.(css|js)$ {
            content_by_lua_block {
                require("rokfoss.autoindex").asset(ngx.var[1])
            }
        }
    }
}
```

`alias` 경로는 반드시 그 서버의 `root` 와 같아야 한다. 다르면 엉뚱한
디렉터리 목록이 나간다.

## 주의

- `location /` 에 `autoindex on` 을 켜두면 안 된다. 켜져 있으면 nginx 가
  403 대신 기본 목록을 내보내서 우리 핸들러가 호출되지 않는다.
- 파일명은 신뢰할 수 없는 입력으로 다룬다. 목록 JSON 은 `<` `>` 를 유니코드로
  이스케이프해서 넣는다. 파일명에 `</script>` 가 들어 있어도 HTML 파서가
  스크립트를 끊지 못한다.
- 캐시 유효시간은 30 초다. 동기화 직후 목록이 잠깐 옛것일 수 있다.
