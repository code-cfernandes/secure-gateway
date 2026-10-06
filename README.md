# secure-gateway

Camada de segurança para serviços self-hosted publicados via **Cloudflare Tunnel** e implantados no **Portainer**.
Um único hostname e uma única porta (o nginx) dão acesso a tudo, cada serviço numa rota:

```
                         Cloudflare                     │  Docker (rede services-net, nenhuma porta publicada)
                                                        │
                                                        │                              ┌─ /ollama/       → ollama:11434       (API key)
 cliente ──HTTPS──► services.<domínio> ──túnel──► cloudflared ──► secure-gateway:8080 ─┼─ /pgadmin/      → pgadmin:80         (Access + login/MFA) ──► postgres:5432
                    (TLS, WAF, Access)                  │        (nginx)               └─ /redisinsight/ → redisinsight:5540  (Access)             ──► redis:6379
```

| Rota | Serviço | Autenticação |
|---|---|---|
| `/ollama/` | API do Ollama | API key do gateway (`Authorization: Bearer`) |
| `/pgadmin/` | pgAdmin (PostgreSQL de desenvolvimento) | Cloudflare Access + login e MFA do pgAdmin |
| `/redisinsight/` | RedisInsight (Redis de desenvolvimento) | Cloudflare Access |
| `/healthz` | Health check | Nenhuma |

**Proteção extra dos painéis**: em produção (`REQUIRE_CF_ACCESS=on`) o gateway recusa com 403 qualquer acesso a `/pgadmin/` e `/redisinsight/` que não tenha passado pelo Cloudflare Access. Se a aplicação do Access for apagada ou mal configurada, o painel fica bloqueado em vez de exposto.

## Estrutura

```
docker-compose.yml          stack do gateway: nginx + cloudflared + rede services-net
docker-compose.local.yml    override para validação local (porta 8080, sem túnel)
nginx/nginx.conf.template   rotas, autenticação, rate limit
docker/gw-keys              CLI de API keys (roda dentro do container)
stacks/postgres/            PostgreSQL 18 + pgAdmin
stacks/redis/               Redis 8 + RedisInsight
scripts/smoke-test.sh       testa bloqueio/liberação da rota /ollama/
```

## 1. Rodar localmente

Ordem: gateway primeiro (ele cria a rede `services-net`), depois as outras stacks.

```bash
# Gateway
echo "CLOUDFLARE_TUNNEL_TOKEN=local" > .env
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
docker exec secure-gateway gw-keys add caio

# PostgreSQL + pgAdmin
cd stacks/postgres && cp .env.example .env    # preencha
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build

# Redis + RedisInsight
cd ../redis && cp .env.example .env           # preencha
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
```

| URL local | O quê |
|---|---|
| http://localhost:8080/pgadmin/ | pgAdmin |
| http://localhost:8080/redisinsight/ | RedisInsight |
| http://localhost:8080/ollama/ | API do Ollama (precisa de um container `ollama` na `services-net`) |
| `localhost:15432` / `localhost:16379` | Postgres / Redis direto, para aplicações locais (opcional) |

Localmente o túnel não sobe e a checagem do Access fica desligada. Para um Ollama de teste:
`docker run -d --name ollama --network services-net -v ollama:/root/.ollama ollama/ollama && docker exec ollama ollama pull qwen2.5:0.5b`

Para limpar: `docker compose -f docker-compose.yml -f docker-compose.local.yml down -v` em cada pasta (redis → postgres → gateway).

## 2. Produção: Cloudflare

1. **Túnel**: *Zero Trust → Networks → Tunnels → Create a tunnel* (Cloudflared). Copie o **token**.
2. **Public Hostname** (um só): `services.<seu-domínio>` → `HTTP` → `secure-gateway:8080`.
3. **Access para os painéis**: *Access → Applications → Self-hosted*, uma aplicação com dois destinos por caminho:
   `services.<seu-domínio>/pgadmin` e `services.<seu-domínio>/redisinsight`, policy **Allow** com *Emails* = os seus endereços.
   **Não** proteja o hostname inteiro: `/ollama/` é usado por programas, que se autenticam com API key.

> O certificado gratuito (Universal SSL) cobre só **um nível** de subdomínio: `services.dominio.com` funciona, `ollama.services.dominio.com` não. Por isso tudo fica num hostname, separado por caminho.

Recomendado: em *Notifications*, ative o **Tunnel Health Alert** para receber e-mail se o túnel cair.

## 3. Produção: Portainer

Crie três stacks (*Stacks → Add stack → Repository*), nesta ordem:

| Stack | Compose path | Variáveis obrigatórias |
|---|---|---|
| gateway | `docker-compose.yml` | `CLOUDFLARE_TUNNEL_TOKEN` |
| postgres | `stacks/postgres/docker-compose.yml` | `POSTGRES_SUPERUSER_PASSWORD`, `APP_DB_PASSWORD`, `PGADMIN_EMAIL`, `PGADMIN_PASSWORD` |
| redis | `stacks/redis/docker-compose.yml` | `REDIS_PASSWORD`, `REDISINSIGHT_ENCRYPTION_KEY` (`openssl rand -hex 32`) |

Variáveis opcionais do gateway:

| Variável | Padrão | Descrição |
|---|---|---|
| `OLLAMA_UPSTREAM` | `ollama:11434` | Ollama na `services-net` |
| `PGADMIN_UPSTREAM` | `pgadmin:80` | pgAdmin |
| `REDISINSIGHT_UPSTREAM` | `redisinsight:5540` | RedisInsight |
| `REQUIRE_CF_ACCESS` | `on` | `on` bloqueia os painéis sem Cloudflare Access |
| `RATE_LIMIT_PER_CLIENT` | `10r/s` | Por API key |
| `RATE_LIMIT_PER_IP` | `20r/s` | Por IP real (`CF-Connecting-IP`) |
| `MAX_BODY_SIZE` | `50m` | Limite do plano Free da Cloudflare: 100 MB |

**Ollama**: conecte o container dele à `services-net` (`external: true`) e **remova os `ports:`**.
Se ele roda direto no host, use `OLLAMA_UPSTREAM=172.17.0.1:11434` e `OLLAMA_HOST=172.17.0.1:11434`.
Depois feche no firewall as portas antigas (11434, 6379, 5432): com o túnel, nenhuma porta de entrada é necessária.

## 4. API keys (rota /ollama/)

No console do container `secure-gateway` (Portainer → Containers → Console) ou `docker exec -it secure-gateway sh`:

```sh
gw-keys add caio      # mostra a chave UMA vez
gw-keys list
gw-keys revoke caio   # vale na hora, sem reiniciar
```

Rotação sem indisponibilidade: crie a nova com outro nome (`gw-keys add app1-2026q4`), troque na aplicação e revogue a antiga.

```bash
curl https://services.<seu-domínio>/ollama/api/chat -H "Authorization: Bearer $GW_KEY" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"oi"}]}'
```
```python
from ollama import Client
client = Client(host="https://services.<seu-domínio>/ollama", headers={"Authorization": f"Bearer {key}"})

from openai import OpenAI
client = OpenAI(base_url="https://services.<seu-domínio>/ollama/v1", api_key=key)
```

Teste: `./scripts/smoke-test.sh https://services.<seu-domínio> <api-key>`

## 5. PostgreSQL + pgAdmin

- Primeiro acesso em `/pgadmin/`: login com `PGADMIN_EMAIL`/`PGADMIN_PASSWORD` e cadastro obrigatório do MFA (app autenticador).
- *Add New Server*: host `postgres`, porta `5432`, banco `app`, usuário `app`, senha `APP_DB_PASSWORD`.
- Truncar: botão direito na tabela → *Truncate*.

O usuário `app` é dono do banco `app`: cria, altera, trunca e apaga tabelas, mas não é superusuário, não cria bancos/usuários e não acessa o banco `postgres`. Toda conexão TCP exige senha (scram). O superusuário fica para manutenção: `docker exec -it postgres psql -U postgres`.

> `APP_DB_*` e o script de permissões rodam só na **primeira** inicialização (volume vazio).

## 6. Redis + RedisInsight

Redis 8 com senha e persistência (AOF). Em `/redisinsight/` o banco `redis-dev` já aparece cadastrado.
Para limpar: *Browser* → filtrar por padrão (ex.: `sessao:*`) → *Bulk Actions → Delete*, ou `FLUSHDB` no *Workbench*.

> O RedisInsight **não tem login próprio** e executa qualquer comando no Redis. Por isso a aplicação do Cloudflare Access e o `REQUIRE_CF_ACCESS=on` são obrigatórios em produção.

## Adicionando outro serviço

- **API** (autenticada por API key): copie o bloco `location /ollama/` em `nginx/nginx.conf.template`.
- **Painel web** (autenticado pelo Access): copie o bloco `location /pgadmin/` (com o `if ($block_ui)`) e adicione o caminho na aplicação do Access.

Nos dois casos: nova variável `*_UPSTREAM` no `docker-compose.yml`, serviço na `services-net` sem `ports:`, redeploy da stack.
A aplicação precisa suportar rodar num subcaminho (procure por "base path", "subpath" ou "proxy path" na documentação dela).

## Logs

Portainer → Containers → secure-gateway → Logs:
```
203.0.113.5 client="caio" user="" [...] "POST /ollama/api/chat HTTP/1.1" 200 1532 rt=4.210 ray=8c1f...
203.0.113.5 client="" user="voce@exemplo.com" [...] "GET /pgadmin/browser/ HTTP/1.1" 200 6775 rt=0.010 ray=8c20...
```
`client` = dono da API key; `user` = e-mail autenticado pelo Cloudflare Access; `ray` = ID da requisição nos logs da Cloudflare.

## Limitações conhecidas

- A checagem do Access verifica a **presença** do token do Access, não a assinatura. Ela protege contra erro de configuração, não contra outro container malicioso na `services-net`.
- Requisições com mais de 100 s sem nenhum byte de resposta recebem 524 da Cloudflare. Use `"stream": true` no Ollama.
- Falhas de API key não passam pelo rate limit do nginx. Com chaves de 256 bits, força bruta é inviável; se quiser, crie uma regra de rate limiting na Cloudflare.
- API keys e senhas ficam no volume e nas variáveis da stack: quem acessa o Portainer/Docker do host tem acesso a elas. Proteja o Portainer com o Cloudflare Access também.
