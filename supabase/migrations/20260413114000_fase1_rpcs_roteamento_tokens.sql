-- Fase 1.6 a 1.10 — RPCs de roteamento, registro de tokens, e gestão de números aprovados
-- Auth S2S real, RLS estendida, contexto de sessão em todas as RPCs chamadas pelo n8n.

-- Adicionar telefone_hash e telefone_enc a private.cadastro
ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS telefone_hash text,
  ADD COLUMN IF NOT EXISTS telefone_enc text;

CREATE INDEX IF NOT EXISTS idx_cadastro_telefone_hash
  ON private.cadastro (telefone_hash)
  WHERE telefone_hash IS NOT NULL;

-- Tabela de credenciais S2S (n8n ↔ Supabase)
CREATE TABLE IF NOT EXISTS private.credenciais_s2s (
  client_id text PRIMARY KEY,
  client_secret_hash text NOT NULL,
  ativo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_credenciais_s2s_set_updated_at ON private.credenciais_s2s;
CREATE TRIGGER trg_credenciais_s2s_set_updated_at
BEFORE UPDATE ON private.credenciais_s2s
FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at();

-- Remover funções auxiliares antigas (falsas / substituídas)
DROP FUNCTION IF EXISTS private.validar_n8n_s2s();
DROP FUNCTION IF EXISTS private.validar_caller();
DROP FUNCTION IF EXISTS private.validar_interno();

-- Permissão temporária para ALTER FUNCTION ... OWNER TO private_rpc_executor (revogada ao final)
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

-- Helper: hash canônico de telefone — garante consistência com os índices
DROP FUNCTION IF EXISTS private.hash_phone_number(text);
CREATE OR REPLACE FUNCTION private.hash_phone_number(p_telefone text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
  SELECT encode(extensions.digest(p_telefone, 'sha256'), 'hex');
$$;

-- Helper: valida usuário autenticado — levanta exceção se não há JWT
CREATE OR REPLACE FUNCTION private.validar_usuario_autenticado()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
BEGIN
  IF public.request_jwt_sub() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: autenticação requerida.'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

-- Helper: valida token S2S — levanta exceção se ausente, inválido ou expirado
CREATE OR REPLACE FUNCTION private.validar_token_s2s(p_token text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'off'
AS $$
DECLARE
  v_decrypted text;
  v_parts text[];
  v_exp bigint;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RAISE EXCEPTION 'Acesso negado: token S2S ausente.'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_decrypted := private.decrypt_value(p_token);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Acesso negado: token S2S inválido.'
      USING ERRCODE = '42501';
  END;

  v_parts := string_to_array(v_decrypted, '|');

  IF array_length(v_parts, 1) < 2 THEN
    RAISE EXCEPTION 'Acesso negado: formato de token S2S inválido.'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_exp := v_parts[2]::bigint;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Acesso negado: token S2S com expiração inválida.'
      USING ERRCODE = '42501';
  END;

  IF v_exp < extract(epoch from now())::bigint THEN
    RAISE EXCEPTION 'Acesso negado: token S2S expirado.'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.session_s2s_validated', 'true', false);
END;
$$;

-- RPC pública: autenticar n8n via S2S — emite token criptografado de 60 s
CREATE OR REPLACE FUNCTION public.rpc_autenticar_s2s(
  p_client_id text,
  p_client_secret text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'off'
AS $$
DECLARE
  v_secret_hash text;
BEGIN
  IF p_client_id IS NULL OR btrim(p_client_id) = '' THEN
    RAISE EXCEPTION 'Acesso negado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_client_secret IS NULL OR btrim(p_client_secret) = '' THEN
    RAISE EXCEPTION 'Acesso negado.'
      USING ERRCODE = '42501';
  END IF;

  SELECT client_secret_hash INTO v_secret_hash
  FROM private.credenciais_s2s
  WHERE client_id = p_client_id AND ativo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acesso negado.'
      USING ERRCODE = '42501';
  END IF;

  IF v_secret_hash IS DISTINCT FROM encode(extensions.digest(p_client_secret, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Acesso negado.'
      USING ERRCODE = '42501';
  END IF;

  RETURN private.encrypt_value(
    p_client_id || '|' || (extract(epoch from (now() + interval '60 seconds'))::bigint)::text
  );
END;
$$;

ALTER FUNCTION public.rpc_autenticar_s2s(text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_autenticar_s2s(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.rpc_autenticar_s2s(text, text) TO authenticated;

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
