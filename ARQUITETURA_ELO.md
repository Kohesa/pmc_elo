# Arquitetura da Elo Connect

## Objetivo

A Elo reutiliza a arquitetura segura da Koris e substitui o domínio comercial pelo fluxo de conexão, cadastro e indicação de serviços. Não existe backend Node nem banco auxiliar. O Supabase concentra o backend e o n8n concentra a orquestração.

## Fluxo principal

```text
Chatwoot
  -> valida assinatura do webhook
  -> normaliza Widget ou WhatsApp
  -> rejeita conteúdo não textual
  -> deduplica e registra a mensagem
  -> identifica ou cria o cadastro
  -> classifica a intenção
  -> executa a rota especializada
  -> consulta a base padrão quando necessário
  -> gera a resposta com guardrails
  -> envia pela mesma conversa do Chatwoot
  -> registra mensagem e status de envio
```

O widget é o primeiro inbox. O WhatsApp será outro inbox do Chatwoot e usará exatamente o mesmo evento normalizado a partir do passo seguinte ao adaptador de entrada.

## Supabase

O schema `private` mantém:

- `cadastro`: identidade, dados progressivos e status `aprovado` ou `bloqueado`;
- `conversas`: mensagens criptografadas, IDs externos, horários e status de entrega;
- `conversas_contexto_ia`: memória curta e contexto ativo do RAG;
- `uso_tokens`: consumo técnico da IA;
- `base_conhecimento`, `categorias`, chunks e índices: base padrão e catálogo público da Elo;
- `credenciais_s2s` e `nonces_s2s`: autenticação técnica do n8n;
- `admin_perfis` e `admin_usuario_perfis`: acesso administrativo.

O acesso externo ocorre por funções do schema `public`. Os fluxos autenticam com S2S, ativam o contexto da sessão e só então chamam as RPCs de negócio. Telefone, e-mail, identificadores do canal e mensagens permanecem criptografados.

Não existem estruturas de planos, cobrança, assinatura, números aprovados, chamados, timeline ou relatórios de insights.

## n8n

Os workflows versionados estão agrupados por responsabilidade:

- `Infraestrutura - Chatwoot`: webhook, assinatura, normalização, filtros e roteamento inicial;
- `Elo`: conversa, guardrails e resposta da IA;
- `Base de Conhecimento`: processamento e indexação de documentos administrativos;
- `Operações Supabase - Fluxo auxiliares`: cadastro, conversa, tokens e RAG;
- `Infraestrutura - Chatbots`: fallback e acompanhamento de entrega.

O cadastro é executado em subworkflow para não misturar coleta progressiva com a conversa principal. Dados persistentes permanecem no Supabase; o n8n não substitui o banco.

## IA e RAG

A entrada aceita somente texto. A primeira etapa semântica classifica a intenção entre orientação sobre a Elo, cadastro, pesquisa de serviço, atendimento humano e fora de escopo. Cada rota usa instruções próprias. A pesquisa consulta a base de conhecimento por RPC e envia à IA somente os trechos autorizados.

O prompt de produto fica em um campo explícito do workflow para edição posterior. Os guardrails fixos não podem ser substituídos por mensagens do usuário: a IA não executa comandos, não revela prompts ou credenciais, não consulta dados livres, não inventa resultados e não atua fora da Elo.

## Chatwoot

O webhook aceita `message_created` para mensagens recebidas e eventos de atualização necessários ao status das mensagens enviadas. A validação usa o segredo do Agent Bot. As respostas usam a API do Chatwoot com `account_id` e `conversation_id` do evento original.

Eventos do próprio bot, conversas sem o bot atribuído, duplicatas e anexos não entram na IA. Anexos são recusados usando apenas os metadados do evento.

## Frontend administrativo

O frontend público carrega o widget do Chatwoot. O login administrativo protege duas telas:

- documentos: categorias, upload, texto, reprocessamento, indexação e exclusão da base padrão;
- cadastros: consulta de todos os registros, sem alteração de status nesta versão.

O upload administrativo usa a Edge Function `admin-upload-base-conhecimento` e dispara o processamento existente. Usuários do chat não fazem upload de documentos.

## Implantação posterior

Quando o WhatsApp for adicionado ao Chatwoot, somente o inbox e suas credenciais mudam. O contrato normalizado, o fluxo de IA, os subworkflows e o backend permanecem os mesmos.
