# Elo Connect

Assistente reativo de conexão e indicação de serviços. O MVP recebe mensagens pelo Chatwoot, orquestra os fluxos no n8n e mantém dados e regras de backend no Supabase.

Para configurar homologação, produção e os deploys automáticos de Supabase e n8n, consulte [DEPLOY_CLOUD.md](DEPLOY_CLOUD.md).

## Arquitetura

```text
Widget Chatwoot (WhatsApp depois)
        -> webhook Chatwoot
        -> n8n local
        -> RPCs públicas do Supabase
        -> schema private
        -> IA + RAG da base padrão da Elo
        -> resposta pela conversa de origem no Chatwoot
```

- `Frontend/`: página com o widget e painel administrativo.
- `n8n/workflows/`: entrada Chatwoot, conversa com IA, RAG e subworkflows operacionais.
- `supabase/migrations/`: schema privado, autenticação S2S, sessão, criptografia, conversas, cadastros e base de conhecimento.
- `supabase/functions/admin-upload-base-conhecimento/`: upload administrativo de documentos.
- `CONTEXTO_PRODUTO_ELO.md`: comportamento e regras de negócio.
- `ARQUITETURA_ELO.md`: componentes, responsabilidades e contratos técnicos.
- `n8n/CHATWOOT.md`: configuração do canal e do webhook.

## Escopo do MVP

- A Elo só responde depois de uma mensagem do usuário.
- O canal aceita apenas texto; anexos são recusados antes de qualquer download.
- Widget e futuro WhatsApp entram pelo mesmo contrato do Chatwoot.
- Cadastros novos começam como `aprovado`; bloqueio é feito por backend ou operação manual.
- A IA consulta apenas a base padrão e o catálogo público administrados pela Elo.
- O painel permite gerenciar os documentos padrão e visualizar todos os cadastros.

Não fazem parte deste projeto cobrança, planos, assinatura, checkout, portal de cliente, chamados, relatórios de insights, timeline, integração direta com a Meta, Callbell, Cloudflare ou banco SQLite.

## Desenvolvimento local

### Supabase

```powershell
supabase start
supabase status
```

API: `http://127.0.0.1:54321`
Studio: `http://127.0.0.1:54323`

### Frontend

```powershell
cd Frontend
npm install
npm run dev
```

Frontend: `http://127.0.0.1:5173`

### n8n

O n8n local usa as variáveis documentadas em `n8n/chatwoot.env.example`. A interface fica em `http://127.0.0.1:5678`.

Os JSONs em `n8n/workflows` são a fonte de verdade. Importe ou atualize esses workflows na instância local antes dos testes integrados.

Depois de recriar o banco, faça o bootstrap dos segredos do Vault e da credencial S2S conforme `n8n/CHATWOOT.md`. As migrations não incluem credenciais ou chaves compartilhadas.

## Validação

```powershell
cd Frontend
npm run lint
npm run build
```

As migrations devem ser validadas em um banco local limpo antes da implantação. A comunicação com tabelas privadas ocorre somente por RPCs públicas autorizadas.
