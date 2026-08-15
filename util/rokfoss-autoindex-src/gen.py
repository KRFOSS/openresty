"""에셋 텍스트에서 nginx 용 C 헤더를 생성한다.

HEAD = doctype + CSS + 본문 골격 + <script id="idx-data"> 여는 태그
TAIL = </script> + JS + 닫는 태그

손으로 C 문자열을 이스케이프하지 않는다. 여기서 바이트 단위로 안전하게 만든다.
"""
import io
import os

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "ngx_http_rokfoss_autoindex.h")


def read(name):
    return io.open(os.path.join(BASE, name), encoding="utf-8").read()


def c_string(name, text):
    """text 를 C u_char 배열 리터럴로 만든다. 줄마다 "..." 로 쪼갠다."""
    lines = []
    lines.append("static u_char %s[] =" % name)
    # 줄 단위로 나누되 개행은 CRLF 로 넣는다(HTTP 응답 관례).
    parts = text.split("\n")
    # 마지막 원소가 빈 문자열이면(파일이 개행으로 끝남) 제거
    if parts and parts[-1] == "":
        parts.pop()
    for i, ln in enumerate(parts):
        esc = (ln.replace("\\", "\\\\")
                 .replace('"', '\\"'))
        lines.append('    "%s\\r\\n"' % esc)
    lines[-1] = lines[-1] + ";"
    return "\n".join(lines)


css = read("idx.css").rstrip("\n")
js = read("idx.js").rstrip("\n")
head = read("head.html").rstrip("\n").replace("__CSS__", css)
tail = read("tail.html").rstrip("\n").replace("__JS__", js)

out = []
out.append("#ifndef _NGX_HTTP_ROKFOSS_AUTOINDEX_H_INCLUDED_")
out.append("#define _NGX_HTTP_ROKFOSS_AUTOINDEX_H_INCLUDED_")
out.append("")
out.append("")
out.append("/* ROKFOSS-Shield autoindex 화면. util/rokfoss-autoindex-src/gen.py 로 생성됨. */")
out.append("")
out.append("")
out.append(c_string("ngx_http_rokfoss_autoindex_head", head))
out.append("")
out.append("")
out.append(c_string("ngx_http_rokfoss_autoindex_tail", tail))
out.append("")
out.append("")
out.append("#endif /* _NGX_HTTP_ROKFOSS_AUTOINDEX_H_INCLUDED_ */")
out.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(out))

# 검증: HEAD 는 data 스크립트 여는 태그로 끝나야 한다
assert head.rstrip().endswith('type="application/json">'), "HEAD 끝이 잘못됨"
assert tail.lstrip().startswith("</script>"), "TAIL 시작이 잘못됨"
print("생성 완료:", OUT)
print("HEAD 바이트:", len(head.encode("utf-8")), " TAIL 바이트:", len(tail.encode("utf-8")))
