# Entrada Chatwoot na Elo Connect

O Chatwoot é a única camada de canais da Elo. No MVP, a conversa começa pelo widget web. A futura inbox de WhatsApp chamará o mesmo webhook e seguirá o mesmo fluxo do n8n.

## Fluxo de entrada

O workflow `workflows/Infraestrutura - Chatwoot/Webhook Chatwoot - Elo Connect.json` expõe:

`POST /webhook/chatwoot/elo`

Conecte o AgentBot da Elo à inbox. O AgentBot envia `message_created` e `message_updated` para a URL configurada. O nó usa `Raw Body` e valida `X-Chatwoot-Signature` e `X-Chatwoot-Timestamp` com HMAC SHA-256 sobre `<timestamp>.<raw_body>`. Entregas com mais de cinco minutos são recusadas. O segredo configurado em `N8N_CHATWOOT_WEBHOOK_SECRET` deve ser o **Segredo do Webhook do AgentBot**.

Não cadastre a mesma URL também em **Integrações → Webhooks**. Esse segundo emissor possui outro segredo e duplicaria os eventos.

O adaptador aceita somente mensagens públicas, recebidas do contato, nas inboxes autorizadas e nos canais `Channel::WebWidget` e `Channel::Whatsapp`. A identidade da sessão é sempre derivada do identificador entregue pelo Chatwoot; o telefone, quando disponível, permanece como dado opcional e criptografado do cadastro. Mensagens enviadas não retornam para a IA. Seus eventos `message_updated` seguem exclusivamente para o subfluxo que grava `sent`, `progress`, `delivered`, `read` ou `failed` no Supabase.

## Guardrail de conteúdo

Somente `content_type: text`, sem anexos e com texto não vazio, entra no núcleo. Áudio, imagem, vídeo, documento, localização, cartões, seletores e qualquer anexo recebem uma resposta curta pedindo uma mensagem escrita. O n8n não baixa o arquivo nem o envia ao modelo.

## Variáveis do n8n

Use `chatwoot.env.example` como referência:

| Variável | Uso |
| --- | --- |
| `NODE_FUNCTION_ALLOW_BUILTIN` | Deve ser `crypto` para permitir a validação HMAC no Code node |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | Deve ser `false` para os Code nodes lerem as configurações da integração |
| `N8N_SUPABASE_URL` | API local, a partir do contêiner n8n: `http://host.docker.internal:54321` |
| `N8N_CLIENT_ID_SUPABASE` | Identificador cadastrado em `private.credenciais_s2s` |
| `N8N_CLIENT_SECRET_SUPABASE` | Segredo correspondente ao hash armazenado na credencial S2S |
| `N8N_CHATWOOT_BASE_URL` | URL do Chatwoot, atualmente `https://chatbot.kohesa.com.br` |
| `N8N_CHATWOOT_API_TOKEN` | Token usado para criar mensagens na conversa |
| `N8N_CHATWOOT_WEBHOOK_SECRET` | Segredo usado para verificar o webhook |
| `N8N_CHATWOOT_ACCOUNT_ID` | Conta autorizada |
| `N8N_CHATWOOT_INBOX_IDS` | Lista de inboxes autorizadas, separada por vírgulas |
| `N8N_CHATWOOT_AGENT_BOT_ID` | Filtro opcional de AgentBot atribuído |
| `N8N_WHATSAPP_BUSINESS_PHONE_NUMBER` | Número empresarial quando o WhatsApp for habilitado |

As respostas usam `POST /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages`, com `message_type: outgoing`, `private: false` e `content_type: text`. Os valores `account_id`, `inbox_id` e `conversation_id` atravessam o fluxo principal e os subworkflows.

## Bootstrap local do Supabase

Um `supabase db reset` deixa credenciais e segredos vazios de propósito. Antes do teste integrado, crie valores exclusivos para o ambiente local no SQL Editor:

```sql
select vault.create_secret(
  '<chave-local-de-criptografia>',
  'encryption_key'
);

insert into private.credenciais_s2s (client_id, client_secret_hash, ativo)
values (
  '<client-id-local>',
  extensions.crypt('<client-secret-local>', extensions.gen_salt('bf')),
  true
)
on conflict (client_id) do update
set client_secret_hash = excluded.client_secret_hash,
    ativo = true,
    updated_at = now();
```

Use os mesmos valores de `client_id` e `client_secret` nas variáveis do n8n. Para o processamento dos documentos administrativos, configure também os segredos do Vault abaixo. O valor de autenticação deve ser o mesmo da credencial **Header Auth** do webhook `processar-documento-base-conhecimento` no n8n.

```sql
select vault.create_secret(
  'http://host.docker.internal:5678/webhook/processar-documento-base-conhecimento',
  'n8n_base_conhecimento_webhook_url'
);

select vault.create_secret(
  '<segredo-header-auth-local>',
  'n8n_base_conhecimento_auth'
);
```

## Widget

O frontend carrega o SDK de `https://chatbot.kohesa.com.br/packs/js/sdk.js` com o website token fornecido para a Elo. O widget só abre o canal; o processamento continua integralmente no n8n.

## Testes

Execute:

```powershell
node --test n8n/tests/chatwoot-webhook.test.cjs
```

Os testes cobrem assinatura, filtros de segurança, Widget e WhatsApp no mesmo contrato, bloqueio de anexos, saídas pela conversa correta e integridade dos grafos.
