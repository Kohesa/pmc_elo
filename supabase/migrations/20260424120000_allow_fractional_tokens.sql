GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

DROP FUNCTION IF EXISTS public.rpc_registrar_tokens(uuid, text, integer, text, text);
DROP FUNCTION IF EXISTS public.rpc_registrar_tokens(uuid, text, numeric, text, text);
CREATE OR REPLACE FUNCTION public.rpc_registrar_tokens(
  p_cadastro_id uuid,
  p_wa_id       text,
  p_tokens      numeric,
  p_mensagem_id text,
  p_token_s2s   text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash       text;
  v_uso_tokens_id uuid;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'registrar_tokens');

  IF p_cadastro_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: cadastro_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_wa_id IS NULL OR btrim(p_wa_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: wa_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_tokens IS NULL OR p_tokens < 0 THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente ou invalido: tokens.'
      USING ERRCODE = '23502';
  END IF;

  IF p_mensagem_id IS NULL OR btrim(p_mensagem_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem_id.'
      USING ERRCODE = '23502';
  END IF;

  v_wa_hash := private.hash_value(p_wa_id);

  PERFORM set_config('app.session_wa_id_hash', v_wa_hash, false);

  INSERT INTO private.uso_tokens (
    cadastro_id,
    wa_id_enc,
    wa_id_hash,
    mensagem_id,
    tokens_consumidos
  ) VALUES (
    p_cadastro_id,
    private.encrypt_value(p_wa_id),
    v_wa_hash,
    p_mensagem_id,
    p_tokens
  )
  RETURNING id INTO v_uso_tokens_id;

  RETURN v_uso_tokens_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Ja existe registro de tokens para este cadastro e mensagem_id.'
      USING ERRCODE = '23505';
END;
$$;

ALTER FUNCTION public.rpc_registrar_tokens(uuid, text, numeric, text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_registrar_tokens(uuid, text, numeric, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_registrar_tokens(uuid, text, numeric, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_registrar_tokens(uuid, text, numeric, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_registrar_tokens(uuid, text, numeric, text, text) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public  FROM private_rpc_executor;
