DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text);
CREATE OR REPLACE FUNCTION public.rpc_set_contexto_sessao(
  p_telefone text,
  p_sessao_token text DEFAULT NULL
) RETURNS text
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'off'
AS $$
DECLARE
  v_hash text := private.hash_phone_number(p_telefone);
  v_exp_epoch bigint := extract(epoch FROM (now() + interval '60 seconds'))::bigint;
  v_payload text;
  v_sessao_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  IF p_sessao_token IS NOT NULL AND trim(p_sessao_token) <> '' THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone);
  END IF;

  v_payload := v_hash || '|' || v_exp_epoch::text;
  v_sessao_token := private.encrypt_value(v_payload);

  PERFORM set_config('app.session_phone_hash', v_hash, false);

  RETURN v_sessao_token;
END;
$$;