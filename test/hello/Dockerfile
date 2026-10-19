# tiny hello-world image: busybox httpd serving a page that names the image's tag, so a check
# can tell which build answers
FROM docker.io/library/busybox:1.37.0

ARG TAG
RUN test -n "$TAG" && mkdir /www && echo "hello from $TAG" > /www/index.html

# nobody; a non-root process can't bind ports below 1024
USER 65534:65534
EXPOSE 8080
# as PID 1, httpd ignores SIGTERM, so a replaced pod would linger for the grace period and keep
# answering; the shell stops it on TERM
CMD ["sh", "-c", "httpd -f -p 8080 -h /www & trap 'kill $!' TERM; wait"]
