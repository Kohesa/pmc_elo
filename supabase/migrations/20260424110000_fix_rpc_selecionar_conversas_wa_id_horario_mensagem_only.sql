-- Ajusta a rpc_selecionar_conversas_por_wa_id para considerar apenas horario_mensagem
-- na ordenacao da mensagem mais recente.
CREATE OR REPLACE FUNCTION public.rpc_selecionar_conversas_por_wa_id(
  p_id_usuario_wa text,
  p_pagina        integer DEFAULT 1,
  p_limite        integer DEFAULT 100,
  p_sessao_token  text    DEFAULT NULL,
  p_mensagem_id   text    DEFAULT NULL
) RETURNS TABLE(
  id                      uuid,
  mensagem_id             text,
  mensagem                text,
  remetente_wa_user_id    text,
  destinatario_wa_user_id text,
  horario_mensagem        timestamptz,
  horario_mensagem_api    timestamptz,
  status_mensagem         text,
  cliente_id              uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text    := private.hash_value(p_id_usuario_wa);
  v_pagina  integer := COALESCE(p_pagina, 1);
  v_limite  integer := LEAST(COALESCE(p_limite, 100), 300);
  v_offset  integer;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  IF v_wa_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'id_usuario_wa fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  IF v_pagina < 1 THEN
    RAISE EXCEPTION 'Parametro invalido: pagina deve ser maior que zero.'
      USING ERRCODE = '22023';
  END IF;

  IF v_limite < 1 THEN
    RAISE EXCEPTION 'Parametro invalido: limite deve ser maior que zero.'
      USING ERRCODE = '22023';
  END IF;

  IF p_mensagem_id IS NOT NULL THEN
    RETURN QUERY
    SELECT
      c.id,
      c.mensagem_id,
      private.decrypt_value(c.mensagem_enc),
      private.decrypt_value(c.remetente_wa_enc),
      private.decrypt_value(c.destinatario_wa_enc),
      c.horario_mensagem,
      c.horario_mensagem_api,
      c.status_mensagem,
      c.cliente_id
    FROM private.conversas c
    WHERE c.mensagem_id = p_mensagem_id
      AND (c.remetente_wa_hash = v_wa_hash OR c.destinatario_wa_hash = v_wa_hash)
    ORDER BY c.horario_mensagem DESC, c.id DESC;

    RETURN;
  END IF;

  v_offset := (v_pagina - 1) * v_limite;

  RETURN QUERY
  WITH matching_rows AS (
    SELECT c.id, c.horario_mensagem AS horario_ordenacao
    FROM private.conversas c
    WHERE c.remetente_wa_hash = v_wa_hash

    UNION

    SELECT c.id, c.horario_mensagem AS horario_ordenacao
    FROM private.conversas c
    WHERE c.destinatario_wa_hash = v_wa_hash
  ),
  paged_ids AS (
    SELECT mr.id
    FROM matching_rows mr
    ORDER BY mr.horario_ordenacao DESC, mr.id DESC
    LIMIT v_limite
    OFFSET v_offset
  )
  SELECT
    c.id,
    c.mensagem_id,
    private.decrypt_value(c.mensagem_enc),
    private.decrypt_value(c.remetente_wa_enc),
    private.decrypt_value(c.destinatario_wa_enc),
    c.horario_mensagem,
    c.horario_mensagem_api,
    c.status_mensagem,
    c.cliente_id
  FROM private.conversas c
  INNER JOIN paged_ids p ON p.id = c.id
  ORDER BY c.horario_mensagem DESC, c.id DESC;
END;
$$;

ALTER FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) TO service_role;