# ROKFOSS GeoIP2 logging bootstrap

The ROKFOSS nginx source patch installs the `custom` access-log format in the
stock nginx configuration. Builds without `ngx_http_geoip2_module` use safe
fallback values directly in the stock configuration, so the default
configuration still starts.

The Docker configuration used by ROKFOSS already loads
`ngx_http_geoip2_module.so` and contains the real `geoip2` blocks. Keep those
blocks. Add the bootstrap below only to supply databases that are missing when
the service starts.

## Docker image wiring

Install `wget` in the runtime stage, then add these instructions after the
dynamic modules are copied:

```dockerfile
COPY --from=builder \
     /src/rokfoss-openresty/util/rokfoss-geoip2-init \
     /src/rokfoss-openresty/util/rokfoss-openresty-entrypoint \
     /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/rokfoss-openresty-entrypoint"]
CMD ["/usr/bin/openresty", "-g", "daemon off;"]
```

The entrypoint invokes the initializer only when the container command is
`openresty` or `nginx`. Shell and diagnostic commands do not trigger a
download.

The initializer:

1. Uses `/etc/nginx/geoip` by default.
2. Downloads only a database that does not already exist or is empty.
3. Downloads to a process-specific temporary file.
4. Rejects unexpectedly small files and, when available, verifies them with
   `mmdblookup`.
5. Atomically renames the verified file into place.

Existing non-empty databases are never replaced. Override the directory or
download mirror with `ROKFOSS_GEOIP_DIR` and `ROKFOSS_GEOIP_BASE_URL`.

The default database source is:

```text
https://raw.githubusercontent.com/infosec-au/GeoLite-mmdb-csv/download
```

## Logging caution

The requested format uses `escape=none` and records POST request bodies.
Passwords, tokens, cookies, personal data, control characters, and line breaks
can therefore be written verbatim. Restrict access to the log and apply
retention and redaction appropriate for each service.
