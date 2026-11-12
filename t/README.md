# 시험(t/) 실행 안내

`t/` 아래 시험은 `prove`로 실행합니다. 환경에 따라 결과가 크게 달라지므로 아래를 먼저 확인하세요.

## 준비

```sh
sudo apt-get install -y libtest-nginx-perl libipc-run3-perl
```

## 실행

```sh
export OPENRESTY_PREFIX=/opt/rokfoss          # 시험할 설치 경로
export TEST_NGINX_BINARY="$OPENRESTY_PREFIX/nginx/sbin/nginx"

cd <저장소 루트>
prove -I. -r t/
```

- **`OPENRESTY_PREFIX`를 반드시 지정하세요.** 지정하지 않으면 `/usr/local/openresty`의
  다른 바이너리를 시험합니다. 그 상태로는 시험이 이유 없이 실패합니다.
- **저장소 루트에서 `-I.`로 실행하세요.** `t/Config.pm`을 `t::Config`로 불러오기 때문에,
  `t/` 안에서 실행하면 모듈을 찾지 못합니다.

## 빌드 옵션

시험은 다음 옵션으로 빌드된 바이너리를 가정합니다.

| 옵션 | 필요한 시험 | 이유 |
| --- | --- | --- |
| `--with-debug` | `001-resolver.t` | 오류 로그의 `parsed a resolver:` 줄을 확인합니다 |
| `--with-stream_realip_module` | `003-stream-proxy-protocol.t` | stream realip 지시어를 씁니다 |
| `--with-stream --with-stream_ssl_module --with-stream_ssl_preread_module` | `005-rokfoss-reload-gate.t`의 stream 블록 | `stream {}` 설정 |
| `--with-http_ssl_module --with-http_v2_module --with-http_v3_module` | 각종 | |

## 알아 둘 것

- 로케일은 `C`로 고정하세요. CI(Ubuntu 22.04, grep 3.7 + UTF-8)에서 한글 주석 줄이
  정규식에 걸려 해시 검사가 실패한 사례가 있습니다.
- `t/000-sanity.t`는 약 455KB입니다.
- `005-rokfoss-reload-gate.t`는 신호가 전달되지 않는 것을 확인하는 시험 4건에서
  각각 최대 5초를 기다립니다. 파일 하나에 약 20초 걸립니다.
- 파일 이름에 `rokfoss`가 들어간 것이 이 저장소에서 추가한 시험입니다.
  (`004-rokfoss-geoip2-init.t`, `004-rokfoss-lua-config-test.t`, `005-rokfoss-reload-gate.t`)
  이름에 `rokfoss`가 없는 시험은 수정 전에 출처를 확인하세요.
