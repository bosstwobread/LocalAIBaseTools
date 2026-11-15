FROM nginx:stable-alpine

ARG BUILD_REVISION=unknown
LABEL org.opencontainers.image.title="ExtensionMarket" \
      org.opencontainers.image.source="https://github.com/bosstwobread/LocalAIBaseTools" \
      org.opencontainers.image.revision="${BUILD_REVISION}"

COPY nginx.conf /etc/nginx/nginx.conf
COPY --chown=101:101 dist/ /usr/share/nginx/html/

USER 101:101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

# Bypass the image's root-oriented entrypoint scripts. Runtime writes go only
# to the deployment's bounded /tmp tmpfs; the image filesystem stays read-only.
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
