# Script de inicialização embutido na imagem: stacks do Portainer (via Git) não lidam bem com bind mounts relativos.
FROM postgres:18-alpine

COPY initdb/10-app-role.sh /docker-entrypoint-initdb.d/10-app-role.sh
RUN chmod 755 /docker-entrypoint-initdb.d/10-app-role.sh
