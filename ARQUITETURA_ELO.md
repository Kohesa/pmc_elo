# Arquitetura da Elo Connect

## Objetivo

A Elo reutiliza a arquitetura segura da Koris e substitui o domínio comercial pelo fluxo de conexão, cadastro e indicação de serviços. Não existe backend Node nem banco auxiliar. O Supabase concentra o backend e o n8n concentra a orquestração.

## Fluxo principal

```text
Chatwoot
  -> valida assinatura do webhook
  -> normaliza Widget ou WhatsApp
  -> rejeita conteúdo não textual
  -> intercepta pedidos de cadastro ou edição e envia o link do frontend
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

- `cadastro`: identidade privada, dados pessoais progressivos, vínculo único com `auth.users` e estados `em_andamento`, `aprovado`, `inativo` ou `bloqueado`;
- `cadastro_auditoria`: trilha sanitizada de criação, edição e conclusão;
- `empresas`: ficha comercial publicável, responsável público opcional, contatos públicos e links autorizados; cada dado pessoal publicável possui autorização própria;
- `cadastro_servicos`: catálogo de serviços vinculado à empresa, com índice lexical e embedding próprios;
- `conversas`: mensagens criptografadas, IDs externos, horários e status de entrega;
- `conversas_contexto_ia`: memória curta e contexto ativo do RAG;
- `uso_tokens`: consumo técnico da IA;
- `base_conhecimento`, `categorias`, chunks e índices: base padrão e catálogo público da Elo;
- `credenciais_s2s` e `nonces_s2s`: autenticação técnica do n8n;
- `admin_perfis` e `admin_usuario_perfis`: acesso administrativo.

O acesso externo ocorre por funções do schema `public`. Os fluxos autenticam com S2S, ativam o contexto da sessão e só então chamam as RPCs de negócio. Telefone, e-mail, identificadores do canal e mensagens pessoais permanecem criptografados. O RAG de serviços recebe exclusivamente a projeção autorizada de `empresas` e `cadastro_servicos`; nunca recebe campos de `cadastro`.

Não existem estruturas de planos, cobrança, assinatura, números aprovados, chamados, timeline ou relatórios de insights.

## n8n

Os workflows versionados estão agrupados por responsabilidade:

- `Infraestrutura - Chatwoot`: webhook, assinatura, normalização, filtros e roteamento inicial;
- `Elo`: conversa, guardrails e resposta da IA;
- `Base de Conhecimento`: processamento e indexação de documentos administrativos;
- `Operações Supabase - Fluxo auxiliares`: cadastro, conversa, tokens e RAG;
- `Infraestrutura - Chatbots`: fallback e acompanhamento de entrega.

O subworkflow `Redirecionar cadastro`, executado antes da conversa com IA, não coleta dados pessoais. Pedidos de criação recebem o link `/cadastro`; pedidos de alteração recebem o link `/entrar`. Cadastro, criação do login e edição acontecem exclusivamente no frontend autenticado.

O usuário autenticado por e-mail e senha no Supabase Auth é a identidade do participante. Widget, WhatsApp e o identificador da conversa são somente transportes. Assim, a pessoa pode autenticar a mesma conta em outro canal sem transferir propriedade por número de WhatsApp ou por cookie do widget. O telefone é contato privado opcional e só pode ser publicado com autorização expressa.

O Chatwoot nunca altera cadastros. O canal serve somente para orientar e encaminhar o usuário à área autenticada.

## IA e RAG

A entrada aceita somente texto. A primeira etapa semântica classifica a intenção entre orientação sobre a Elo, cadastro, pesquisa de serviço, detalhe de empresa, atendimento humano e fora de escopo. Cada rota usa instruções próprias. A pesquisa usa recuperação híbrida e reranking sobre o catálogo de serviços. A primeira resposta usa cards padronizados; perguntas posteriores sobre uma empresa usam linguagem natural, sempre limitada à ficha pública autorizada.

O prompt de produto fica em um campo explícito do workflow para edição posterior. Os guardrails fixos não podem ser substituídos por mensagens do usuário: a IA não executa comandos, não revela prompts ou credenciais, não consulta dados livres, não inventa resultados e não atua fora da Elo.

## Chatwoot

O webhook aceita `message_created` para mensagens recebidas e eventos de atualização necessários ao status das mensagens enviadas. A validação usa o segredo do Agent Bot. As respostas usam a API do Chatwoot com `account_id` e `conversation_id` do evento original.

Eventos do próprio bot, conversas sem o bot atribuído, duplicatas e anexos não entram na IA. Anexos são recusados usando apenas os metadados do evento.

## Frontend

O frontend público carrega o widget do Chatwoot e também oferece a área do participante:

- `/cadastro`: ficha da empresa/serviço seguida da criação do login por e-mail e senha;
- `/entrar`: acesso por e-mail e senha ou, no primeiro acesso, por código enviado ao e-mail confirmado;
- `/meu-cadastro`: visualização e edição do cadastro pertencente ao `auth_user_id` autenticado.

O login administrativo permanece separado e protege duas telas:

- documentos: categorias, upload, texto, reprocessamento, indexação e exclusão da base padrão;
- cadastros: abas separadas para empresas públicas e pessoas/contatos privados, sem alteração de status nesta versão.

O upload administrativo usa a Edge Function `admin-upload-base-conhecimento` e dispara o processamento existente. Usuários do chat não fazem upload de documentos.

## Implantação posterior

Quando o WhatsApp for adicionado ao Chatwoot, somente o inbox e suas credenciais mudam. O contrato normalizado, o fluxo de IA, os subworkflows e o backend permanecem os mesmos.
