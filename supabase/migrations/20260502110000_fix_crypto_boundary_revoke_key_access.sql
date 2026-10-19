-- Fecha o crypto boundary: remove o acesso direto de private_rpc_executor
-- a private.get_encryption_key().
--
-- Problema: migration 20260402110000 concedeu EXECUTE em get_encryption_key()
-- a private_rpc_executor. Com isso, rpc_autenticar_s2s (OWNER private_rpc_executor,
-- definida em 20260420120000) chamava get_encryption_key() diretamente para computar
-- o HMAC do token S2S — a chave mestra ficava disponivel como variavel dentro de
-- uma funcao owned pela role de aplicacao.
--
-- Solucao:
--   1. Criar private.compute_hmac_s2s(payload) — OWNER postgres — que encapsula
--      a chamada a get_encryption_key() e retorna apenas o resultado do HMAC.
--   2. Recriar rpc_autenticar_s2s usando compute_hmac_s2s em vez de buscar a chave.
--   3. REVOKE EXECUTE em get_encryption_key() de private_rpc_executor.
--
-- Apos esta migration, nenhuma funcao owned por private_rpc_executor tem acesso
-- direto ao material criptografico. A chave permanece dentro do contexto postgres.
-- encrypt_value, decrypt_value e validar_token_s2s ja eram OWNER postgres — corretos.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;

-- 1) Nova funcao: encapsula HMAC sem expor a chave para private_rpc_executor
CREATE OR REPLACE FUNCTION private.compute_hmac_s2s(p_payload text)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
BEGIN
  RETURN encode(
    extensions.hmac(p_payload, private.get_encryption_key(), 'sha256'),
    'hex'
  );
END;
$$;

ALTER FUNCTION private.compute_hmac_s2s(text) OWNER TO postgres;

REVOKE ALL ON FUNCTION private.compute_hmac_s2s(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.compute_hmac_s2s(text) FROM anon;
REVOKE ALL ON FUNCTION private.compute_hmac_s2s(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.compute_hmac_s2s(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.compute_hmac_s2s(text) TO private_rpc_executor;

-- 2) Recriar rpc_autenticar_s2s sem acesso direto a get_encryption_key()
--    Unica mudanca logica: v_enc_key removido; HMAC calculado via compute_hmac_s2s.
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
    'identificar', 'set_contexto', 'registrar_tokens'
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

-- 3) Revogar acesso direto a get_encryption_key() de private_rpc_executor.
--    A partir daqui nenhuma funcao de aplicacao pode obter a chave mestra via SQL.
REVOKE EXECUTE ON FUNCTION private.get_encryption_key() FROM private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
