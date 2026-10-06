#!/bin/sh
# Roda só na primeira inicialização (volume de dados vazio).
# Cria um usuário sem superpoderes, dono do próprio banco: pode criar, alterar,
# truncar e apagar tabelas ali, mas não mexe em outros bancos nem no servidor.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v app_user="$APP_DB_USER" -v app_pass="$APP_DB_PASSWORD" -v app_db="$APP_DB_NAME" <<'EOSQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE :"app_db" OWNER :"app_user";
REVOKE ALL ON DATABASE :"app_db" FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB_NAME" \
  -v app_user="$APP_DB_USER" <<'EOSQL'
ALTER SCHEMA public OWNER TO :"app_user";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
EOSQL
