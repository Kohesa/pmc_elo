-- Corrige referencias legadas phone_hash/telefone_hash apos migracao para wa_id como identificador primario.
-- Objetivos:
-- 1) Ajustar RLS para wa_id como caminho principal (com fallback transicional quando necessario)
-- 2) Corrigir RPCs legadas que ainda quebram por colunas/assinaturas antigas
-- 3) Preservar compatibilidade para chamadas com sessao_token em RPCs que nao recebem wa_id

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- 1) Helpers de sessao
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.require_session_wa_id_hash()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
DECLARE
  v_hash text := private.get_session_wa_id_hash();
BEGIN
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Contexto da sessao nao definido.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_hash;
END;
$$;

ALTER FUNCTION private.require_session_wa_id_hash() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.require_session_wa_id_hash() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.require_session_wa_id_hash() FROM anon;
REVOKE ALL ON FUNCTION private.require_session_wa_id_hash() FROM authenticated;
REVOKE ALL ON FUNCTION private.require_session_wa_id_hash() FROM service_role;
GRANT EXECUTE ON FUNCTION private.require_session_wa_id_hash() TO private_rpc_executor;

-- Alias de compatibilidade: chamadas legadas para require_session_phone_hash()
-- passam a validar exclusivamente o contexto de wa_id.
CREATE OR REPLACE FUNCTION private.require_session_phone_hash()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
DECLARE
  v_hash text := private.get_session_wa_id_hash();
BEGIN
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Contexto da sessao nao definido.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_hash;
END;
$$;

ALTER FUNCTION private.require_session_phone_hash() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.require_session_phone_hash() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.require_session_phone_hash() FROM anon;
REVOKE ALL ON FUNCTION private.require_session_phone_hash() FROM authenticated;
REVOKE ALL ON FUNCTION private.require_session_phone_hash() FROM service_role;
GRANT EXECUTE ON FUNCTION private.require_session_phone_hash() TO private_rpc_executor;

-- Compatibilidade: algumas RPCs antigas ainda restauram contexto apenas com sessao_token.
DROP FUNCTION IF EXISTS private.activate_session_context(text);
CREATE OR REPLACE FUNCTION private.activate_session_context(
  p_sessao_token text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_payload   text;
  v_hash      text;
  v_exp_epoch bigint;
BEGIN
  IF p_sessao_token IS NULL OR trim(p_sessao_token) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: sessao_token.'
      USING ERRCODE = '23502';
  END IF;

  BEGIN
    v_payload := private.decrypt_value(p_sessao_token);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END;

  v_hash := split_part(v_payload, '|', 1);

  BEGIN
    v_exp_epoch := split_part(v_payload, '|', 2)::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END;

  IF v_hash IS NULL OR trim(v_hash) = '' OR v_exp_epoch IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  IF v_exp_epoch <= extract(epoch FROM now())::bigint THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.session_wa_id_hash', v_hash, false);

  RETURN v_hash;
END;
$$;

ALTER FUNCTION private.activate_session_context(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.activate_session_context(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.activate_session_context(text) FROM anon;
REVOKE ALL ON FUNCTION private.activate_session_context(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.activate_session_context(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.activate_session_context(text) TO private_rpc_executor;

-- ---------------------------------------------------------------------------

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
