# secure-gateway

Camada de segurança para serviços self-hosted (Ollama, Redis, ...) publicados via **Cloudflare Tunnel** e implantados no **Portainer**.

```
                       Cloudflare                       │  Docker (rede services-net, sem portas publicadas)
                                                        │
 cliente HTTP ──HTTPS──► services.<domínio> ──túnel──► cloudflared ──► secure-gateway:8080 ──/ollama/──► ollama:11434
                         (TLS, WAF, DDoS)               │                (API key, rate limit, logs)
                                                        │
 cliente Redis ─cloudflared access─► redis.<domínio> ─túnel─► cloudflared ──────────────────────────────► redis:6379
                (Cloudflare Access: service token)      │                                     (requirepass)
```

| Camada | O que faz |
|---|---|
| Cloudflare | HTTPS com certificado válido, esconde o IP do servidor, nenhuma porta aberta |
| `secure-gateway` (nginx) | API key por cliente, rate limit por cliente e por IP real (`CF-Connecting-IP`), roteamento por caminho, log de quem chamou o quê |
| Cloudflare Access | Autenticação de conexões TCP (Redis), que não têm como usar API key |

## 1. Preparar os serviços

Os serviços **não podem publicar portas** (`ports:`). Eles só precisam estar na rede `services-net`.
Essa rede é criada pela stack do gateway; nas stacks do Ollama/Redis, declare-a como externa:

```yaml
services:
  ollama:
    image: ollama/ollama
    container_name: ollama
    # sem "ports:"
    networks: [services-net]
    volumes: [ollama:/root/.ollama]

  redis:
    image: redis:7-alpine
    container_name: redis
    command: redis-server --requirepass ${REDIS_PASSWORD}
    networks: [services-net]

networks:
  services-net:
    external: true
volumes:
  ollama:
```

> Se o Ollama roda instalado direto no host (fora do Docker), use `OLLAMA_UPSTREAM=<ip-da-bridge>:11434` (normalmente `172.17.0.1`), configure `OLLAMA_HOST=172.17.0.1:11434` no serviço e bloqueie a porta 11434 no firewall.

Feche as portas antigas (`11434`, `6379`) no firewall/roteador: depois do túnel, o servidor não precisa de nenhuma porta de entrada.

## 2. Criar o túnel na Cloudflare

1. **Zero Trust → Networks → Tunnels → Create a tunnel** (tipo *Cloudflared*), copie o **token**.
2. Em **Public Hostnames**, adicione:

| Hostname | Service |
|---|---|
| `services.<seu-domínio>` | `HTTP` → `secure-gateway:8080` |
| `redis.<seu-domínio>` | `TCP` → `redis:6379` |

> O certificado gratuito (Universal SSL) cobre só **um nível** de subdomínio: `services.dominio.com` funciona, `ollama.services.dominio.com` não. Por isso o gateway roteia por caminho (`/ollama/`) num único hostname.

3. **Proteja o Redis com Access**: *Access → Applications → Self-hosted*, hostname `redis.<seu-domínio>`, policy com ação **Service Auth** incluindo um **Service Token** (*Access → Service Auth → Create*). Guarde o Client ID/Secret.

Opcional para o hostname HTTP: regras de WAF/rate limiting da Cloudflare (por exemplo, bloquear países ou limitar `/ollama/*`).

## 3. Implantar no Portainer

**Stacks → Add stack → Repository**, aponte para este repositório (compose path `docker-compose.yml`) e em *Environment variables* defina:

| Variável | Exemplo |
|---|---|
| `CLOUDFLARE_TUNNEL_TOKEN` | token do passo 2 (**obrigatória**) |
| `OLLAMA_UPSTREAM` | `ollama:11434` |
| `RATE_LIMIT_PER_CLIENT` | `10r/s` |
| `RATE_LIMIT_PER_IP` | `20r/s` |
| `MAX_BODY_SIZE` | `50m` (o plano Free da Cloudflare limita uploads a 100 MB) |

O Portainer faz o build da imagem `secure-gateway` a partir do `Dockerfile`. Implante essa stack **antes** das stacks dos serviços (ela cria a rede `services-net`).

Sem Portainer: `cp .env.example .env`, preencha e rode `docker compose up -d --build`.

## 4. Gerenciar API keys

No Portainer: **Containers → secure-gateway → Console** (`/bin/sh`), ou via terminal com `docker exec -it secure-gateway ...`:

```sh
gw-keys add caio      # mostra a chave UMA vez
gw-keys list
gw-keys revoke caio   # vale na hora, sem reiniciar
```

As chaves ficam no volume `gateway-secrets` e sobrevivem a redeploys/atualizações da stack.

## 5. Usar

### Ollama
```bash
curl https://services.<seu-domínio>/ollama/api/chat \
  -H "Authorization: Bearer $OLLAMA_KEY" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"oi"}]}'
```

```python
from ollama import Client
client = Client(host="https://services.<seu-domínio>/ollama",
                headers={"Authorization": f"Bearer {key}"})

from openai import OpenAI   # API compatível com OpenAI
client = OpenAI(base_url="https://services.<seu-domínio>/ollama/v1", api_key=key)
```

### Redis
O cliente roda o `cloudflared` localmente, que abre uma porta local ligada ao túnel:
```bash
cloudflared access tcp --hostname redis.<seu-domínio> --url 127.0.0.1:6379 \
  --service-token-id <CLIENT_ID> --service-token-secret <CLIENT_SECRET>

redis-cli -h 127.0.0.1 -p 6379 -a <REDIS_PASSWORD>
```
Aplicações em outros servidores fazem o mesmo (por exemplo, `cloudflared` como sidecar no compose delas).

### Testar
```bash
./scripts/smoke-test.sh https://services.<seu-domínio> <api-key>
```

## Adicionando outro serviço HTTP

Copie o bloco `location /ollama/ { ... }` em `nginx/nginx.conf.template`, troque o prefixo e o upstream (adicione a variável no `docker-compose.yml`), conecte o serviço à `services-net` e faça redeploy da stack. As mesmas API keys valem para todos os serviços.

## Logs

Portainer → Containers → secure-gateway → Logs:
```
203.0.113.5 client="caio" [...] "POST /ollama/api/chat HTTP/1.1" 200 1532 rt=4.210 ray=8c1f...
```
O `ray` permite cruzar a requisição com os logs da Cloudflare.

## Limitações conhecidas

- Requisições com mais de 100 segundos sem enviar nenhum byte recebem erro 524 da Cloudflare. Com `"stream": true` (o padrão do Ollama) isso não acontece; com `"stream": false` em gerações longas, sim.
- Falhas de autenticação não passam pelo rate limit do nginx (a checagem ocorre antes). Como as chaves têm 256 bits, força bruta é inviável. Se quiser barrar o volume mesmo assim, crie uma regra de rate limiting na Cloudflare.
- As API keys ficam em texto puro no volume (`chmod 600`). Quem tem acesso ao Portainer/Docker do host tem acesso a elas.
