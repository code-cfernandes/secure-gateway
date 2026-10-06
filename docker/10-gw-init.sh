#!/bin/sh
# Garante que o arquivo de chaves existe (volume novo começa vazio).
set -eu
mkdir -p /etc/nginx/secrets
[ -f /etc/nginx/secrets/api_keys.map ] || touch /etc/nginx/secrets/api_keys.map
chmod 600 /etc/nginx/secrets/api_keys.map
