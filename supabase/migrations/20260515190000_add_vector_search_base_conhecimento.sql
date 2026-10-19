-- Infraestrutura vetorial da base de conhecimento global da Elo.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.get_session_auth_user_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
  SELECT NULLIF(current_setting('app.session_auth_user_id', true), '')::uuid;
$$;

ALTER FUNCTION private.get_session_auth_user_id() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.get_session_auth_user_id() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.get_session_auth_user_id() TO private_rpc_executor;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.rpc_autenticar_s2s(
  p_client_id text,
  p_client_secret text,
  p_scope text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'off'
AS $$
DECLARE
  v_secret_hash text;
  v_nonce text;
  v_payload text;
  v_hmac text;
  v_exp_epoch bigint := extract(epoch from (now() + interval '60 seconds'))::bigint;
  v_expires_at timestamptz := now() + interval '60 seconds';
  v_scopes_validos text[] := ARRAY[
    'identificar',
    'set_contexto',
    'registrar_tokens',
    'processar_base_conhecimento',
    'indexar_base_conhecimento',
    'buscar_contexto_ia',
    'gerar_embedding'
  ];
BEGIN
  IF p_client_id IS NULL OR btrim(p_client_id) = ''
     OR p_client_secret IS NULL OR btrim(p_client_secret) = '' THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  IF p_scope IS NULL OR btrim(p_scope) = '' OR NOT (p_scope = ANY(v_scopes_validos)) THEN
    RAISE EXCEPTION 'Acesso negado: scope invalido ou ausente.' USING ERRCODE = '42501';
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
  ELSIF v_secret_hash IS DISTINCT FROM encode(extensions.digest(p_client_secret, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  v_nonce := encode(extensions.gen_random_bytes(16), 'hex');
  INSERT INTO private.nonces_s2s (nonce, client_id, expires_at)
  VALUES (v_nonce, p_client_id, v_expires_at);

  v_payload := p_client_id || '|' || v_exp_epoch::text || '|' || v_nonce || '|' || p_scope;
  v_hmac := private.compute_hmac_s2s(v_payload);
  RETURN private.encrypt_value(v_payload || '|' || v_hmac);
END;
$$;

ALTER FUNCTION public.rpc_autenticar_s2s(text, text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_autenticar_s2s(text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_validar_geracao_embedding_s2s(p_token_s2s text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'gerar_embedding');
END;
$$;

ALTER FUNCTION public.rpc_validar_geracao_embedding_s2s(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_validar_geracao_embedding_s2s(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_validar_geracao_embedding_s2s(text) TO service_role;

ALTER TABLE private.base_conhecimento
  ADD COLUMN IF NOT EXISTS status_indexacao text,
  ADD COLUMN IF NOT EXISTS indexado_em timestamptz,
  ADD COLUMN IF NOT EXISTS qtd_chunks integer,
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS erro_indexacao text;

UPDATE private.base_conhecimento SET status_indexacao = 'pendente' WHERE status_indexacao IS NULL;

ALTER TABLE private.base_conhecimento
  ALTER COLUMN status_indexacao SET DEFAULT 'pendente',
  ALTER COLUMN status_indexacao SET NOT NULL,
  DROP CONSTRAINT IF EXISTS base_conhecimento_status_indexacao_check,
  ADD CONSTRAINT base_conhecimento_status_indexacao_check
    CHECK (status_indexacao IN ('pendente', 'indexando', 'indexado', 'erro')),
  DROP CONSTRAINT IF EXISTS base_conhecimento_qtd_chunks_check,
  ADD CONSTRAINT base_conhecimento_qtd_chunks_check CHECK (qtd_chunks IS NULL OR qtd_chunks >= 0);

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_status_indexacao
  ON private.base_conhecimento (status_indexacao, hora_criacao DESC, id DESC);

CREATE TABLE IF NOT EXISTS private.base_conhecimento_chunks (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  base_conhecimento_id uuid NOT NULL,
  cadastro_id uuid,
  categoria_id uuid,
  chunk_index integer NOT NULL,
  conteudo text NOT NULL,
  conteudo_hash text NOT NULL,
  embedding extensions.vector(384) NOT NULL,
  embedding_model text NOT NULL,
  token_count integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT base_conhecimento_chunks_documento_fkey
    FOREIGN KEY (base_conhecimento_id) REFERENCES private.base_conhecimento (id) ON DELETE CASCADE,
  CONSTRAINT base_conhecimento_chunks_categoria_fkey
    FOREIGN KEY (categoria_id) REFERENCES private.categorias (id) ON DELETE SET NULL,
  CONSTRAINT base_conhecimento_chunks_elo_global_check CHECK (cadastro_id IS NULL),
  CONSTRAINT base_conhecimento_chunks_chunk_index_check CHECK (chunk_index >= 0),
  CONSTRAINT base_conhecimento_chunks_conteudo_not_blank_check CHECK (btrim(conteudo) <> ''),
  CONSTRAINT base_conhecimento_chunks_conteudo_hash_not_blank_check CHECK (btrim(conteudo_hash) <> ''),
  CONSTRAINT base_conhecimento_chunks_embedding_model_not_blank_check CHECK (btrim(embedding_model) <> ''),
  CONSTRAINT base_conhecimento_chunks_token_count_check CHECK (token_count > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_base_conhecimento_chunks_documento_chunk
  ON private.base_conhecimento_chunks (base_conhecimento_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_base_conhecimento_chunks_documento
  ON private.base_conhecimento_chunks (base_conhecimento_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_base_conhecimento_chunks_embedding_hnsw
  ON private.base_conhecimento_chunks USING hnsw (embedding extensions.vector_cosine_ops);

DROP TRIGGER IF EXISTS trg_base_conhecimento_chunks_set_updated_at ON private.base_conhecimento_chunks;
CREATE TRIGGER trg_base_conhecimento_chunks_set_updated_at
BEFORE UPDATE ON private.base_conhecimento_chunks
FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

ALTER TABLE private.base_conhecimento_chunks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS base_conhecimento_chunks_select ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_select ON private.base_conhecimento_chunks FOR SELECT
  USING (
    cadastro_id IS NULL
    AND (
      current_setting('app.session_base_conhecimento_publica_validated', true) = 'true'
      OR current_setting('app.session_base_conhecimento_default_validated', true) = 'true'
      OR current_setting('app.session_indexacao_publica_validated', true) = 'true'
    )
  );

DROP POLICY IF EXISTS base_conhecimento_chunks_insert ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_insert ON private.base_conhecimento_chunks FOR INSERT
  WITH CHECK (
    cadastro_id IS NULL
    AND current_setting('app.session_indexacao_publica_validated', true) = 'true'
  );

DROP POLICY IF EXISTS base_conhecimento_chunks_update ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_update ON private.base_conhecimento_chunks FOR UPDATE
  USING (cadastro_id IS NULL AND current_setting('app.session_indexacao_publica_validated', true) = 'true')
  WITH CHECK (cadastro_id IS NULL AND current_setting('app.session_indexacao_publica_validated', true) = 'true');

DROP POLICY IF EXISTS base_conhecimento_chunks_delete ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_delete ON private.base_conhecimento_chunks FOR DELETE
  USING (cadastro_id IS NULL AND current_setting('app.session_indexacao_publica_validated', true) = 'true');

REVOKE ALL ON TABLE private.base_conhecimento_chunks FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.base_conhecimento_chunks TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
