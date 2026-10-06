# Config embutida na imagem: stacks do Portainer (via Git) não lidam bem com bind mounts relativos.
FROM nginx:1.27-alpine

ENV NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx

COPY nginx/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY docker/10-gw-init.sh /docker-entrypoint.d/10-gw-init.sh
COPY docker/gw-keys /usr/local/bin/gw-keys

RUN chmod 755 /docker-entrypoint.d/10-gw-init.sh /usr/local/bin/gw-keys

VOLUME /etc/nginx/secrets
