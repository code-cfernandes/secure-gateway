#!/usr/bin/env bash
# Verifica se o gateway está bloqueando/permitindo corretamente.
#   ./scripts/smoke-test.sh <url-base> <api-key>
#   ex.: ./scripts/smoke-test.sh https://services.exemplo.com sk-gw-...
set -uo pipefail

URL="${1:?uso: $0 <url-base> <api-key>}"
KEY="${2:?uso: $0 <url-base> <api-key>}"
fail=0

check() { # descrição, status esperado, args do curl...
  local desc="$1" want="$2"; shift 2
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [[ "$got" == "$want" ]]; then echo "OK   $desc ($got)"; else echo "FAIL $desc (esperado $want, veio $got)"; fail=1; fi
}

check "healthz sem auth"         200 "$URL/healthz"
check "rota desconhecida"        404 "$URL/qualquer-coisa"
check "Ollama sem API key"       401 "$URL/ollama/api/tags"
check "Ollama com key inválida"  401 -H "Authorization: Bearer sk-gw-invalida" "$URL/ollama/api/tags"
check "Ollama com key válida"    200 -H "Authorization: Bearer $KEY" "$URL/ollama/api/tags"

exit $fail
