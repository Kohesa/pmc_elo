-- RAG contextual da Elo: indice global de documentos e memoria curta por conversa.
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;


CREATE TABLE IF NOT EXISTS private.base_conhecimento_documentos_indice (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  base_conhecimento_id uuid NOT NULL UNIQUE,
  cadastro_id uuid,
  categoria_id uuid,
  titulo_detectado_enc text,
  tipo_documento text,
  resumo_busca_enc text NOT NULL,
  assuntos_json_enc text,
  entidades_json_enc text,
  embedding_resumo extensions.vector(384) NOT NULL,
  embedding_model text NOT NULL,
  token_count integer NOT NULL,
  indice_hash text NOT NULL,
  indexado_em timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT base_conhecimento_documentos_indice_documento_fkey
    FOREIGN KEY (base_conhecimento_id) REFERENCES private.base_conhecimento (id) ON DELETE CASCADE,
  CONSTRAINT base_conhecimento_documentos_indice_categoria_fkey
    FOREIGN KEY (categoria_id) REFERENCES private.categorias (id) ON DELETE SET NULL,
  CONSTRAINT base_conhecimento_documentos_indice_global_check CHECK (cadastro_id IS NULL),
  CONSTRAINT base_conhecimento_documentos_indice_embedding_model_check CHECK (btrim(embedding_model) <> ''),
  CONSTRAINT base_conhecimento_documentos_indice_token_count_check CHECK (token_count > 0),
  CONSTRAINT base_conhecimento_documentos_indice_hash_check CHECK (btrim(indice_hash) <> ''),
  CONSTRAINT base_conhecimento_documentos_indice_tipo_check
    CHECK (tipo_documento IS NULL OR btrim(tipo_documento) <> '')
);

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_documentos_indice_publica
  ON private.base_conhecimento_documentos_indice (categoria_id, indexado_em DESC);
CREATE INDEX IF NOT EXISTS idx_base_conhecimento_documentos_indice_embedding
  ON private.base_conhecimento_documentos_indice
  USING hnsw (embedding_resumo extensions.vector_cosine_ops);

DROP TRIGGER IF EXISTS trg_base_conhecimento_documentos_indice_set_updated_at
  ON private.base_conhecimento_documentos_indice;
CREATE TRIGGER trg_base_conhecimento_documentos_indice_set_updated_at
BEFORE UPDATE ON private.base_conhecimento_documentos_indice
FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

ALTER TABLE private.base_conhecimento_documentos_indice ENABLE ROW LEVEL SECURITY;

-- Politicas iniciais para o pipeline global. A migration de administracao
-- acrescenta a verificacao do perfil admin_docs.
DROP POLICY IF EXISTS base_conhecimento_documentos_indice_select
  ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_select
  ON private.base_conhecimento_documentos_indice FOR SELECT
  USING (
    cadastro_id IS NULL
    AND (
      current_setting('app.session_base_conhecimento_publica_validated', true) = 'true'
      OR current_setting('app.session_base_conhecimento_default_validated', true) = 'true'
      OR current_setting('app.session_indexacao_publica_validated', true) = 'true'
    )
  );

DROP POLICY IF EXISTS base_conhecimento_documentos_indice_insert
  ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_insert
  ON private.base_conhecimento_documentos_indice FOR INSERT
  WITH CHECK (
    cadastro_id IS NULL
    AND current_setting('app.session_indexacao_publica_validated', true) = 'true'
  );

DROP POLICY IF EXISTS base_conhecimento_documentos_indice_update
  ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_update
  ON private.base_conhecimento_documentos_indice FOR UPDATE
  USING (
    cadastro_id IS NULL
    AND current_setting('app.session_indexacao_publica_validated', true) = 'true'
  )
  WITH CHECK (
    cadastro_id IS NULL
    AND current_setting('app.session_indexacao_publica_validated', true) = 'true'
  );

DROP POLICY IF EXISTS base_conhecimento_documentos_indice_delete
  ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_delete
  ON private.base_conhecimento_documentos_indice FOR DELETE
  USING (
    cadastro_id IS NULL
    AND current_setting('app.session_indexacao_publica_validated', true) = 'true'
  );

REVOKE ALL ON TABLE private.base_conhecimento_documentos_indice FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.base_conhecimento_documentos_indice TO private_rpc_executor;

CREATE TABLE IF NOT EXISTS private.conversas_contexto_ia (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  cadastro_id uuid NOT NULL,
  whatsapp_user_id_hash text NOT NULL,
  documento_ativo_id uuid,
  documento_ativo_titulo_enc text,
  assunto_ativo_enc text,
  entidades_ativas_json_enc text,
  ultima_pergunta_enc text,
  ultima_resposta_enc text,
  score_documento_ativo double precision,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '60 minutes'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversas_contexto_ia_cadastro_fkey
    FOREIGN KEY (cadastro_id) REFERENCES private.cadastro (id) ON DELETE CASCADE,
  CONSTRAINT conversas_contexto_ia_documento_ativo_fkey
    FOREIGN KEY (documento_ativo_id) REFERENCES private.base_conhecimento (id) ON DELETE SET NULL,
  CONSTRAINT conversas_contexto_ia_wa_hash_check CHECK (btrim(whatsapp_user_id_hash) <> ''),
  CONSTRAINT conversas_contexto_ia_score_check
    CHECK (score_documento_ativo IS NULL OR score_documento_ativo BETWEEN -1 AND 1),
  CONSTRAINT conversas_contexto_ia_unique UNIQUE (cadastro_id, whatsapp_user_id_hash)
);

CREATE INDEX IF NOT EXISTS idx_conversas_contexto_ia_cadastro_wa
  ON private.conversas_contexto_ia (cadastro_id, whatsapp_user_id_hash);
CREATE INDEX IF NOT EXISTS idx_conversas_contexto_ia_cleanup
  ON private.conversas_contexto_ia (expires_at, id);

DROP TRIGGER IF EXISTS trg_conversas_contexto_ia_set_updated_at ON private.conversas_contexto_ia;
CREATE TRIGGER trg_conversas_contexto_ia_set_updated_at
BEFORE UPDATE ON private.conversas_contexto_ia
FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

ALTER TABLE private.conversas_contexto_ia ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.contexto_ia_pertence_sessao(
  p_cadastro_id uuid,
  p_whatsapp_user_id_hash text,
  p_documento_ativo_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT
    current_setting('app.session_s2s_validated', true) = 'true'
    AND private.get_session_wa_id_hash() IS NOT NULL
    AND p_whatsapp_user_id_hash = private.get_session_wa_id_hash()
    AND EXISTS (
      SELECT 1 FROM private.cadastro c
      WHERE c.id = p_cadastro_id
        AND c.id_usuario_wa_hash = private.get_session_wa_id_hash()
        AND c.status <> 'bloqueado'
    )
    AND (
      p_documento_ativo_id IS NULL
      OR EXISTS (
        SELECT 1 FROM private.base_conhecimento bc
        WHERE bc.id = p_documento_ativo_id
          AND bc.cadastro_id IS NULL
      )
    );
$$;

ALTER FUNCTION private.contexto_ia_pertence_sessao(uuid, text, uuid) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.contexto_ia_pertence_sessao(uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.contexto_ia_pertence_sessao(uuid, text, uuid) TO private_rpc_executor;

DROP POLICY IF EXISTS conversas_contexto_ia_select ON private.conversas_contexto_ia;
CREATE POLICY conversas_contexto_ia_select ON private.conversas_contexto_ia FOR SELECT
  USING (private.contexto_ia_pertence_sessao(cadastro_id, whatsapp_user_id_hash, documento_ativo_id));

DROP POLICY IF EXISTS conversas_contexto_ia_insert ON private.conversas_contexto_ia;
CREATE POLICY conversas_contexto_ia_insert ON private.conversas_contexto_ia FOR INSERT
  WITH CHECK (private.contexto_ia_pertence_sessao(cadastro_id, whatsapp_user_id_hash, documento_ativo_id));

DROP POLICY IF EXISTS conversas_contexto_ia_update ON private.conversas_contexto_ia;
CREATE POLICY conversas_contexto_ia_update ON private.conversas_contexto_ia FOR UPDATE
  USING (private.contexto_ia_pertence_sessao(cadastro_id, whatsapp_user_id_hash, documento_ativo_id))
  WITH CHECK (private.contexto_ia_pertence_sessao(cadastro_id, whatsapp_user_id_hash, documento_ativo_id));

DROP POLICY IF EXISTS conversas_contexto_ia_delete ON private.conversas_contexto_ia;
CREATE POLICY conversas_contexto_ia_delete ON private.conversas_contexto_ia FOR DELETE
  USING (private.contexto_ia_pertence_sessao(cadastro_id, whatsapp_user_id_hash, documento_ativo_id));

REVOKE ALL ON TABLE private.conversas_contexto_ia FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.conversas_contexto_ia TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;