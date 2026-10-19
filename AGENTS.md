# AGENTS.md — Elo Connect

## Produto

Este repositório adapta a arquitetura funcional da Koris para a Elo Connect. Consulte `CONTEXTO_PRODUTO_ELO.md`, `ARQUITETURA_ELO.md` e `n8n/CHATWOOT.md` antes de alterar a solução.

## Regras obrigatórias

- Preservar Supabase, schema `private`, RPCs públicas, S2S, sessão, criptografia e subworkflows úteis da arquitetura original.
- Executar Supabase e n8n localmente no desenvolvimento.
- Receber e enviar mensagens somente pelo Chatwoot.
- Usar o widget no MVP e acrescentar WhatsApp depois pelo mesmo contrato normalizado.
- Aceitar somente texto e recusar anexos antes de qualquer download.
- Não criar backend Node, SQLite, schema paralelo ou tabelas duplicadas.
- Não acessar tabelas privadas diretamente; toda operação externa deve usar RPCs públicas autorizadas.
- Estabelecer o contexto de sessão antes das RPCs de conversa, cadastro ou RAG.
- Criptografar telefone, e-mail, identificadores do canal e mensagens no schema `private`.
- Tratar os JSONs em `n8n/workflows` como fonte de verdade dos fluxos.

## Responsabilidades

- Supabase: persistência, validação, segurança, autenticação S2S, sessão, criptografia e regras de dados.
- n8n: orquestração, triagem, chamadas de IA, RAG, envio pelo Chatwoot e subfluxos.
- Chatwoot: porta de entrada e saída, primeiro pelo widget e depois por WhatsApp.
- Frontend: página do widget e painel administrativo de documentos e cadastros.

## Fora do escopo

Cobrança, planos, assinatura, checkout, área de cliente, números aprovados, chamados, timeline, relatórios de insights, integração direta com a Meta, Callbell, Cloudflare e uploads enviados pelo chat não pertencem à Elo.
