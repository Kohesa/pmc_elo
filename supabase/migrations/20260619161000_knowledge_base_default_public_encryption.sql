-- Base de conhecimento global da Elo, administrada somente pelo perfil admin_docs.
-- Os escopos publico e default_elo atendem o catalogo e o contexto padrao da IA.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;
GRANT CREATE ON SCHEMA private TO private_rpc_executor;

ALTER TABLE private.base_conhecimento
  ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS criado_por_auth_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_tags
  ON private.base_conhecimento USING gin (tags);
CREATE INDEX IF NOT EXISTS idx_base_conhecimento_system_scope
  ON private.base_conhecimento (hora_criacao DESC, id DESC)
  WHERE cadastro_id IS NULL;

ALTER TABLE private.base_conhecimento
  DROP CONSTRAINT IF EXISTS base_conhecimento_tags_not_null_items_check,
  ADD CONSTRAINT base_conhecimento_tags_not_null_items_check
    CHECK (array_position(tags, NULL) IS NULL),
  DROP CONSTRAINT IF EXISTS base_conhecimento_scope_tags_check,
  ADD CONSTRAINT base_conhecimento_scope_tags_check
    CHECK (
      cadastro_id IS NULL
      AND NOT (
        tags @> ARRAY['publico']::text[]
        AND tags @> ARRAY['default_elo']::text[]
      )
    ) NOT VALID;

ALTER TABLE private.categorias
  DROP CONSTRAINT IF EXISTS categorias_elo_global_check,
  ADD CONSTRAINT categorias_elo_global_check CHECK (cadastro_id IS NULL) NOT VALID;
ALTER TABLE private.base_conhecimento_chunks
  DROP CONSTRAINT IF EXISTS base_conhecimento_chunks_elo_global_check,
  ADD CONSTRAINT base_conhecimento_chunks_elo_global_check CHECK (cadastro_id IS NULL) NOT VALID;
ALTER TABLE private.base_conhecimento_chunks_pendentes
  ALTER COLUMN cadastro_id DROP NOT NULL,
  DROP CONSTRAINT IF EXISTS base_conhecimento_chunks_pendentes_elo_global_check,
  ADD CONSTRAINT base_conhecimento_chunks_pendentes_elo_global_check CHECK (cadastro_id IS NULL) NOT VALID;
ALTER TABLE private.base_conhecimento_documentos_indice
  DROP CONSTRAINT IF EXISTS base_conhecimento_documentos_indice_global_check,
  ADD CONSTRAINT base_conhecimento_documentos_indice_global_check CHECK (cadastro_id IS NULL) NOT VALID;

UPDATE private.categorias SET cadastro_id = NULL;
UPDATE private.base_conhecimento SET cadastro_id = NULL;
UPDATE private.base_conhecimento_chunks SET cadastro_id = NULL;
UPDATE private.base_conhecimento_chunks_pendentes SET cadastro_id = NULL;
UPDATE private.base_conhecimento_documentos_indice SET cadastro_id = NULL;

ALTER TABLE private.base_conhecimento VALIDATE CONSTRAINT base_conhecimento_scope_tags_check;
ALTER TABLE private.categorias VALIDATE CONSTRAINT categorias_elo_global_check;
ALTER TABLE private.base_conhecimento_chunks VALIDATE CONSTRAINT base_conhecimento_chunks_elo_global_check;
ALTER TABLE private.base_conhecimento_chunks_pendentes VALIDATE CONSTRAINT base_conhecimento_chunks_pendentes_elo_global_check;
ALTER TABLE private.base_conhecimento_documentos_indice VALIDATE CONSTRAINT base_conhecimento_documentos_indice_global_check;

UPDATE private.base_conhecimento
SET tags = ARRAY['publico']::text[]
WHERE cardinality(tags) = 0;

CREATE OR REPLACE FUNCTION private.base_conhecimento_has_tag(p_id uuid, p_tag text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM private.base_conhecimento bc
    WHERE bc.id = p_id
      AND bc.cadastro_id IS NULL
      AND bc.tags @> ARRAY[p_tag]::text[]
  );
$$;

ALTER FUNCTION private.base_conhecimento_has_tag(uuid, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.base_conhecimento_has_tag(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.base_conhecimento_has_tag(uuid, text) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.base_conhecimento_is_system_scope(p_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM private.base_conhecimento bc
    WHERE bc.id = p_id
      AND bc.cadastro_id IS NULL
      AND (
        bc.tags @> ARRAY['publico']::text[]
        OR bc.tags @> ARRAY['default_elo']::text[]
      )
  );
$$;

ALTER FUNCTION private.base_conhecimento_is_system_scope(uuid) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.base_conhecimento_is_system_scope(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.base_conhecimento_is_system_scope(uuid) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.normalizar_kb_admin_escopo(p_escopo text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path TO 'pg_catalog'
AS $$
DECLARE
  v_escopo text := lower(btrim(COALESCE(p_escopo, '')));
BEGIN
  IF v_escopo NOT IN ('publico', 'default_elo') THEN
    RAISE EXCEPTION 'Escopo invalido: %. Use publico ou default_elo.', p_escopo
      USING ERRCODE = '22023';
  END IF;
  RETURN v_escopo;
END;
$$;

ALTER FUNCTION private.normalizar_kb_admin_escopo(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.normalizar_kb_admin_escopo(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.normalizar_kb_admin_escopo(text) TO private_rpc_executor;

-- O texto permanece criptografado no schema private.
UPDATE private.base_conhecimento
SET documento = private.encrypt_value(documento)
WHERE documento IS NOT NULL;
UPDATE private.base_conhecimento_chunks
SET conteudo = private.encrypt_value(conteudo)
WHERE conteudo IS NOT NULL;

-- Funcoes globais antigas sem autenticacao administrativa deixam de existir.
DROP FUNCTION IF EXISTS public.rpc_salvar_indice_documento_base_conhecimento_publica_s2s(
  uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
);
DROP FUNCTION IF EXISTS public.rpc_listar_documentos_publicos_sem_indice_contextual_s2s(text, integer);
DROP FUNCTION IF EXISTS public.rpc_obter_amostra_documento_base_conhecimento_publica_s2s(uuid, text, integer);

UPDATE private.base_conhecimento
SET
  status_processamento = 'erro',
  status_indexacao = 'erro',
  erro_indexacao = COALESCE(NULLIF(erro_indexacao, ''), 'Documento sem escopo publico/default_elo.')
WHERE NOT (
  tags @> ARRAY['publico']::text[]
  OR tags @> ARRAY['default_elo']::text[]
);

-- Storage exclusivo do painel administrativo de documentos.
CREATE OR REPLACE FUNCTION public.request_can_access_base_conhecimento_storage_path(p_root_folder text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'private', 'auth'
AS $$
  SELECT p_root_folder = '_system'
    AND public.request_has_admin_profile('admin_docs');
$$;

ALTER FUNCTION public.request_can_access_base_conhecimento_storage_path(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.request_can_access_base_conhecimento_storage_path(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_can_access_base_conhecimento_storage_path(text) TO authenticated;

DROP POLICY IF EXISTS storage_base_conhecimento_select ON storage.objects;
CREATE POLICY storage_base_conhecimento_select ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'base-conhecimento-documentos'
  AND public.request_can_access_base_conhecimento_storage_path((storage.foldername(name))[1])
);

DROP POLICY IF EXISTS storage_base_conhecimento_insert ON storage.objects;
CREATE POLICY storage_base_conhecimento_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'base-conhecimento-documentos'
  AND public.request_can_access_base_conhecimento_storage_path((storage.foldername(name))[1])
);

DROP POLICY IF EXISTS storage_base_conhecimento_update ON storage.objects;
CREATE POLICY storage_base_conhecimento_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'base-conhecimento-documentos'
  AND public.request_can_access_base_conhecimento_storage_path((storage.foldername(name))[1])
)
WITH CHECK (
  bucket_id = 'base-conhecimento-documentos'
  AND public.request_can_access_base_conhecimento_storage_path((storage.foldername(name))[1])
);

DROP POLICY IF EXISTS storage_base_conhecimento_delete ON storage.objects;
CREATE POLICY storage_base_conhecimento_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'base-conhecimento-documentos'
  AND public.request_can_access_base_conhecimento_storage_path((storage.foldername(name))[1])
);

-- Predicados reutilizados pelas politicas das tabelas da base.
CREATE OR REPLACE FUNCTION private.kb_admin_request()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
  SELECT public.request_has_admin_profile('admin_docs')
    OR (
      current_setting('app.session_s2s_validated', true) = 'true'
      AND private.get_session_auth_user_id() IS NOT NULL
      AND private.auth_user_has_admin_profile(private.get_session_auth_user_id(), 'admin_docs')
    );
$$;

ALTER FUNCTION private.kb_admin_request() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.kb_admin_request() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.kb_admin_request() TO private_rpc_executor, authenticated;

CREATE OR REPLACE FUNCTION private.kb_search_request(p_base_conhecimento_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT private.kb_admin_request()
    OR (
      current_setting('app.session_base_conhecimento_publica_validated', true) = 'true'
      AND private.base_conhecimento_has_tag(p_base_conhecimento_id, 'publico')
    )
    OR (
      current_setting('app.session_base_conhecimento_default_validated', true) = 'true'
      AND private.base_conhecimento_has_tag(p_base_conhecimento_id, 'default_elo')
    );
$$;

ALTER FUNCTION private.kb_search_request(uuid) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.kb_search_request(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.kb_search_request(uuid) TO private_rpc_executor, authenticated;

-- Categorias: somente administradores de documentos.
DROP POLICY IF EXISTS categorias_select ON private.categorias;
DROP POLICY IF EXISTS categorias_insert ON private.categorias;
DROP POLICY IF EXISTS categorias_update ON private.categorias;
DROP POLICY IF EXISTS categorias_delete ON private.categorias;
CREATE POLICY categorias_select ON private.categorias FOR SELECT USING (private.kb_admin_request());
CREATE POLICY categorias_insert ON private.categorias FOR INSERT WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY categorias_update ON private.categorias FOR UPDATE
  USING (cadastro_id IS NULL AND private.kb_admin_request())
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY categorias_delete ON private.categorias FOR DELETE USING (cadastro_id IS NULL AND private.kb_admin_request());

-- Documentos: administracao pelo painel; leitura pelo RAG conforme o escopo.
DROP POLICY IF EXISTS base_conhecimento_select ON private.base_conhecimento;
DROP POLICY IF EXISTS base_conhecimento_insert ON private.base_conhecimento;
DROP POLICY IF EXISTS base_conhecimento_update ON private.base_conhecimento;
DROP POLICY IF EXISTS base_conhecimento_delete ON private.base_conhecimento;
CREATE POLICY base_conhecimento_select ON private.base_conhecimento FOR SELECT
  USING (cadastro_id IS NULL AND private.kb_search_request(id));
CREATE POLICY base_conhecimento_insert ON private.base_conhecimento FOR INSERT
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_update ON private.base_conhecimento FOR UPDATE
  USING (cadastro_id IS NULL AND private.kb_admin_request())
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_delete ON private.base_conhecimento FOR DELETE
  USING (cadastro_id IS NULL AND private.kb_admin_request());

-- Chunks processados.
DROP POLICY IF EXISTS base_conhecimento_chunks_select ON private.base_conhecimento_chunks;
DROP POLICY IF EXISTS base_conhecimento_chunks_insert ON private.base_conhecimento_chunks;
DROP POLICY IF EXISTS base_conhecimento_chunks_update ON private.base_conhecimento_chunks;
DROP POLICY IF EXISTS base_conhecimento_chunks_delete ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_select ON private.base_conhecimento_chunks FOR SELECT
  USING (cadastro_id IS NULL AND private.kb_search_request(base_conhecimento_id));
CREATE POLICY base_conhecimento_chunks_insert ON private.base_conhecimento_chunks FOR INSERT
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_chunks_update ON private.base_conhecimento_chunks FOR UPDATE
  USING (cadastro_id IS NULL AND private.kb_admin_request())
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_chunks_delete ON private.base_conhecimento_chunks FOR DELETE
  USING (cadastro_id IS NULL AND private.kb_admin_request());

-- Fila de chunks pendentes.
DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_select ON private.base_conhecimento_chunks_pendentes;
DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_insert ON private.base_conhecimento_chunks_pendentes;
DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_update ON private.base_conhecimento_chunks_pendentes;
DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_delete ON private.base_conhecimento_chunks_pendentes;
CREATE POLICY base_conhecimento_chunks_pendentes_select ON private.base_conhecimento_chunks_pendentes FOR SELECT
  USING (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_chunks_pendentes_insert ON private.base_conhecimento_chunks_pendentes FOR INSERT
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_chunks_pendentes_update ON private.base_conhecimento_chunks_pendentes FOR UPDATE
  USING (cadastro_id IS NULL AND private.kb_admin_request())
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_chunks_pendentes_delete ON private.base_conhecimento_chunks_pendentes FOR DELETE
  USING (cadastro_id IS NULL AND private.kb_admin_request());

-- Indice contextual por documento.
DROP POLICY IF EXISTS base_conhecimento_documentos_indice_select ON private.base_conhecimento_documentos_indice;
DROP POLICY IF EXISTS base_conhecimento_documentos_indice_insert ON private.base_conhecimento_documentos_indice;
DROP POLICY IF EXISTS base_conhecimento_documentos_indice_update ON private.base_conhecimento_documentos_indice;
DROP POLICY IF EXISTS base_conhecimento_documentos_indice_delete ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_select ON private.base_conhecimento_documentos_indice FOR SELECT
  USING (cadastro_id IS NULL AND private.kb_search_request(base_conhecimento_id));
CREATE POLICY base_conhecimento_documentos_indice_insert ON private.base_conhecimento_documentos_indice FOR INSERT
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_documentos_indice_update ON private.base_conhecimento_documentos_indice FOR UPDATE
  USING (cadastro_id IS NULL AND private.kb_admin_request())
  WITH CHECK (cadastro_id IS NULL AND private.kb_admin_request());
CREATE POLICY base_conhecimento_documentos_indice_delete ON private.base_conhecimento_documentos_indice FOR DELETE
  USING (cadastro_id IS NULL AND private.kb_admin_request());

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
