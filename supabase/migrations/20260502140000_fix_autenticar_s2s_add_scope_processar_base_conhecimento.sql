-- Reaplica rpc_autenticar_s2s adicionando o escopo 'processar_base_conhecimento'
-- que foi removido acidentalmente em 20260502110000.
--
-- 20260502110000 recriou rpc_autenticar_s2s com 6 escopos para fechar o crypto
-- boundary (compute_hmac_s2s em vez de get_encryption_key diretamente).
-- Porem 20260501140000 havia adicionado o 7o escopo 'processar_base_conhecimento',
-- necessario para que o n8n possa chamar rpc_autenticar_s2s antes de finalizar
-- o processamento de documentos da base de conhecimento.
--
-- Esta migration e identica a 20260502110000 exceto pelo escopo adicionado.
-- A funcao ja usa compute_hmac_s2s (nao acessa get_encryption_key diretamente).

CREATE OR REPLACE FUNCTION public.rpc_autenticar_s2s(
  p_client_id     text,
  p_client_secret text,
  p_scope         text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'off'
AS $$
DECLARE
  v_secret_hash    text;
  v_nonce          text;
  v_payload        text;
  v_hmac           text;
  v_exp_epoch      bigint      := extract(epoch from (now() + interval '60 seconds'))::bigint;
  v_expires_at     timestamptz := now() + interval '60 seconds';
  v_scopes_validos text[] := ARRAY[
    'identificar',
    'set_contexto',
    'registrar_tokens',
    'processar_base_conhecimento'
  ];
BEGIN
  IF p_client_id IS NULL OR btrim(p_client_id) = '' THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  IF p_client_secret IS NULL OR btrim(p_client_secret) = '' THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  IF p_scope IS NULL OR btrim(p_scope) = '' OR NOT (p_scope = ANY(v_scopes_validos)) THEN
    RAISE EXCEPTION 'Acesso negado: scope invalido ou ausente.'
      USING ERRCODE = '42501';
  END IF;

  SELECT client_secret_hash INTO v_secret_hash
  FROM private.credenciais_s2s
  WHERE client_id = p_client_id AND ativo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  IF left(v_secret_hash, 2) = '$2' THEN
    IF extensions.crypt(p_client_secret, v_secret_hash) IS DISTINCT FROM v_secret_hash THEN
      RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF v_secret_hash IS DISTINCT FROM encode(extensions.digest(p_client_secret, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_nonce := encode(extensions.gen_random_bytes(16), 'hex');

  INSERT INTO private.nonces_s2s (nonce, client_id, expires_at)
  VALUES (v_nonce, p_client_id, v_expires_at);

  v_payload := p_client_id || '|' || v_exp_epoch::text || '|' || v_nonce || '|' || p_scope;
  v_hmac    := private.compute_hmac_s2s(v_payload);

  RETURN private.encrypt_value(v_payload || '|' || v_hmac);
END;
$$;

ALTER FUNCTION public.rpc_autenticar_s2s(text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_autenticar_s2s(text, text, text) TO service_role;
