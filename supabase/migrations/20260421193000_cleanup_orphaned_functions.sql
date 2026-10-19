-- Remove funções órfãs que nunca foram dropadas antes de serem substituídas por versões
-- novas nas migrations de Fase 2. A coexistência cria ambiguidade de overload (código 42725)
-- quando PostgreSQL não consegue escolher qual versão chamar.

-- 1. private.activate_session_context(text, text)
--    Criada em: 20260402193000_session_uuid_context.sql
--    Substituída por: (text, text DEFAULT NULL, text DEFAULT NULL) em 20260420120000_fase2
--    Impacto: rpc_selecionar_conversas_por_numero e rpc_selecionar_cadastro_por_telefone
--    chamam com 2 args — ambas as versões correspondem, causando erro 42725.
DROP FUNCTION IF EXISTS private.activate_session_context(text, text);

-- 2. private.validar_token_s2s(text)
--    Criada em: 20260413114000_fase1_rpcs_roteamento_tokens.sql
--    Substituída por: (text, text DEFAULT NULL) em 20260420120000_fase2
--    Impacto: as RPCs S2S chamam com 1 argumento e ambas as versoes
--    correspondem, causando erro 42725.
DROP FUNCTION IF EXISTS private.validar_token_s2s(text);

-- 3. public.rpc_set_contexto_sessao(text, text)
--    Criada em: 20260402193000 e atualizada em 20260403193000 (ainda com auth.uid() + JWT).
--    Substituída por: (text, text, text, text) em 20260420120000_fase2.
--    Impacto: versão antiga usa JWT e não S2S — se chamada acidentalmente retorna
--    "Usuario nao autenticado" em vez de processar corretamente.
DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text, text);
