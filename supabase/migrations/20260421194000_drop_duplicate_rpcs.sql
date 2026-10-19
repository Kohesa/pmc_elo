-- Remove versões órfãs de RPCs que acumularam ao longo das migrations sem DROP explícito.
-- Em cada caso, a migration de Fase 2 criou uma versão nova com assinatura diferente mas
-- só dropou a versão imediatamente anterior, deixando versões ainda mais antigas no banco.
--
-- Versões mantidas (atuais, definidas em 20260420120000_fase2_converter_rpcs_para_s2s.sql):
--   rpc_atualizar_cadastro (uuid, text×10)  — 11 params
--   rpc_inserir_cadastro   (text×11)        — 11 params
--   rpc_inserir_conversa   (text×4, uuid, text×3) — 8 params

-- rpc_atualizar_cadastro
-- Órfã de 20260329183000 (8 params: p_id + 7 campos, sem sessao_token)
DROP FUNCTION IF EXISTS public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text);
-- Órfã de 20260402193000 (9 params: 8 anteriores + p_sessao_token)
DROP FUNCTION IF EXISTS public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text);

-- rpc_inserir_cadastro
-- Órfã de 20260329183000 (8 params: p_telefone + 7 campos, sem sessao_token)
DROP FUNCTION IF EXISTS public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text);
-- Órfã de 20260402193000 (9 params: 8 anteriores + p_sessao_token)
DROP FUNCTION IF EXISTS public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text);

-- rpc_inserir_conversa
-- Órfã de 20260408110000 (7 params: mensagem_id, remetente, destinatario, mensagem, cliente_id, horario_mensagem_api timestamptz, sessao_token)
-- Fase 2 só dropou a versão de 8 params (text×4, uuid, text×3), não esta de 7 params com timestamptz
DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text);

-- rpc_atualizar_conversa
-- Versao antiga com remetente/destinatario textuais e contexto por telefone.
DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(text, text, text, text, uuid, text, text);
