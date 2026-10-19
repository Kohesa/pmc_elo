-- Restaura o parametro obrigatorio horario_mensagem_api na rpc_inserir_conversa
-- e garante persistencia explicita na tabela private.conversas.
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, text);
DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text);

CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id             text,
  p_mensagem                text,
  p_remetente_wa_user_id    text,
  p_destinatario_wa_user_id text,
  p_cliente_id              uuid        DEFAULT NULL,
  p_horario_mensagem_api    timestamptz DEFAULT NULL,
  p_sessao_token            text        DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id                 uuid;
  v_session_hash       text;
  v_remetente_hash     text;
  v_destinatario_hash  text;
  v_session_cadastro_id uuid;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_remetente_wa_user_id);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  v_session_cadastro_id := private.get_session_cadastro_id();

  IF p_mensagem_id IS NULL OR trim(p_mensagem_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_mensagem IS NULL OR trim(p_mensagem) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem.'
      USING ERRCODE = '23502';
  END IF;

  IF p_remetente_wa_user_id IS NULL OR trim(p_remetente_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: remetente_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_destinatario_wa_user_id IS NULL OR trim(p_destinatario_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: destinatario_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_horario_mensagem_api IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: horario_mensagem_api.'
      USING ERRCODE = '23502';
  END IF;

  v_session_hash      := private.get_session_wa_id_hash();
  v_remetente_hash    := private.hash_value(p_remetente_wa_user_id);
  v_destinatario_hash := private.hash_value(p_destinatario_wa_user_id);

  -- Remetente ou destinatario deve corresponder a sessao ativa
  IF v_remetente_hash <> v_session_hash AND v_destinatario_hash <> v_session_hash THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  IF p_cliente_id IS NOT NULL
     AND v_session_cadastro_id IS NOT NULL
     AND p_cliente_id <> v_session_cadastro_id THEN
    RAISE EXCEPTION 'cliente_id fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.conversas (
    mensagem_id,
    mensagem_enc,
    remetente_wa_enc,
    remetente_wa_hash,
    destinatario_wa_enc,
    destinatario_wa_hash,
    cliente_id,
    horario_mensagem_api
  ) VALUES (
    p_mensagem_id,
    private.encrypt_value(p_mensagem),
    private.encrypt_value(p_remetente_wa_user_id),
    v_remetente_hash,
    private.encrypt_value(p_destinatario_wa_user_id),
    v_destinatario_hash,
    COALESCE(p_cliente_id, v_session_cadastro_id),
    p_horario_mensagem_api
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public  FROM private_rpc_executor;
