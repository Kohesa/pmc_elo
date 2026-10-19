GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

-- Adiciona fila persistida para indexacao lenta de documentos grandes.
-- Regra de uso: somente documentos com mais de 500 chunks entram nesta trilha.

CREATE TABLE IF NOT EXISTS private.base_conhecimento_chunks_pendentes (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  base_conhecimento_id uuid NOT NULL,
  cadastro_id uuid NOT NULL,
  categoria_id uuid,
  chunk_index integer NOT NULL,
  conteudo text NOT NULL,
  conteudo_hash text NOT NULL,
  token_count integer NOT NULL,
  status text NOT NULL DEFAULT 'pendente',
  tentativas integer NOT NULL DEFAULT 0,
  erro text,
  embedding_model text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT base_conhecimento_chunks_pendentes_documento_fkey
    FOREIGN KEY (base_conhecimento_id) REFERENCES private.base_conhecimento (id) ON DELETE CASCADE,
  CONSTRAINT base_conhecimento_chunks_pendentes_cadastro_fkey
    FOREIGN KEY (cadastro_id) REFERENCES private.cadastro (id) ON DELETE CASCADE,
  CONSTRAINT base_conhecimento_chunks_pendentes_categoria_fkey
    FOREIGN KEY (categoria_id) REFERENCES private.categorias (id) ON DELETE SET NULL,
  CONSTRAINT base_conhecimento_chunks_pendentes_chunk_index_check
    CHECK (chunk_index >= 0),
  CONSTRAINT base_conhecimento_chunks_pendentes_conteudo_not_blank_check
    CHECK (btrim(conteudo) <> ''),
  CONSTRAINT base_conhecimento_chunks_pendentes_conteudo_hash_not_blank_check
    CHECK (btrim(conteudo_hash) <> ''),
  CONSTRAINT base_conhecimento_chunks_pendentes_token_count_check
    CHECK (token_count > 0),
  CONSTRAINT base_conhecimento_chunks_pendentes_status_check
    CHECK (status IN ('pendente', 'concluido', 'erro')),
  CONSTRAINT base_conhecimento_chunks_pendentes_tentativas_check
    CHECK (tentativas >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_base_conhecimento_chunks_pendentes_documento_chunk
  ON private.base_conhecimento_chunks_pendentes (base_conhecimento_id, chunk_index);

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_chunks_pendentes_documento_status
  ON private.base_conhecimento_chunks_pendentes (base_conhecimento_id, status, chunk_index);

DROP TRIGGER IF EXISTS trg_base_conhecimento_chunks_pendentes_set_updated_at
  ON private.base_conhecimento_chunks_pendentes;
CREATE TRIGGER trg_base_conhecimento_chunks_pendentes_set_updated_at
BEFORE UPDATE ON private.base_conhecimento_chunks_pendentes
FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at();

ALTER TABLE private.base_conhecimento_chunks_pendentes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_select
  ON private.base_conhecimento_chunks_pendentes;
CREATE POLICY base_conhecimento_chunks_pendentes_select
  ON private.base_conhecimento_chunks_pendentes
  FOR SELECT
  USING (
    (SELECT current_setting('app.session_s2s_validated', true)) = 'true'
    AND private.get_session_auth_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = base_conhecimento_chunks_pendentes.cadastro_id
        AND c.auth_user_id = private.get_session_auth_user_id()
    )
  );

DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_insert
  ON private.base_conhecimento_chunks_pendentes;
CREATE POLICY base_conhecimento_chunks_pendentes_insert
  ON private.base_conhecimento_chunks_pendentes
  FOR INSERT
  WITH CHECK (
    (SELECT current_setting('app.session_s2s_validated', true)) = 'true'
    AND private.get_session_auth_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = base_conhecimento_chunks_pendentes.cadastro_id
        AND c.auth_user_id = private.get_session_auth_user_id()
    )
  );

DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_update
  ON private.base_conhecimento_chunks_pendentes;
CREATE POLICY base_conhecimento_chunks_pendentes_update
  ON private.base_conhecimento_chunks_pendentes
  FOR UPDATE
  USING (
    (SELECT current_setting('app.session_s2s_validated', true)) = 'true'
    AND private.get_session_auth_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = base_conhecimento_chunks_pendentes.cadastro_id
        AND c.auth_user_id = private.get_session_auth_user_id()
    )
  )
  WITH CHECK (
    (SELECT current_setting('app.session_s2s_validated', true)) = 'true'
    AND private.get_session_auth_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = base_conhecimento_chunks_pendentes.cadastro_id
        AND c.auth_user_id = private.get_session_auth_user_id()
    )
  );

DROP POLICY IF EXISTS base_conhecimento_chunks_pendentes_delete
  ON private.base_conhecimento_chunks_pendentes;
CREATE POLICY base_conhecimento_chunks_pendentes_delete
  ON private.base_conhecimento_chunks_pendentes
  FOR DELETE
  USING (
    (SELECT current_setting('app.session_s2s_validated', true)) = 'true'
    AND private.get_session_auth_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = base_conhecimento_chunks_pendentes.cadastro_id
        AND c.auth_user_id = private.get_session_auth_user_id()
    )
  );

REVOKE ALL ON TABLE private.base_conhecimento_chunks_pendentes FROM PUBLIC;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_pendentes FROM anon;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_pendentes FROM authenticated;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_pendentes FROM service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE private.base_conhecimento_chunks_pendentes
  TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_chunks jsonb,
  p_token_s2s text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_cadastro_id uuid;
  v_categoria_id uuid;
  v_status_indexacao text;
  v_qtd_chunks integer := COALESCE(jsonb_array_length(p_chunks), 0);
  v_rows integer := 0;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'indexar_base_conhecimento');

  IF p_documento_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_chunks IS NULL OR jsonb_typeof(p_chunks) <> 'array' OR v_qtd_chunks = 0 THEN
    RAISE EXCEPTION 'Parametro invalido: chunks deve ser um array nao vazio.'
      USING ERRCODE = '22023';
  END IF;

  IF v_qtd_chunks <= 500 THEN
    RAISE EXCEPTION 'Fila pendente reservada para documentos com mais de 500 chunks: recebido %.', v_qtd_chunks
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, false);

  SELECT bc.cadastro_id, bc.area_empresa, bc.status_indexacao
    INTO v_cadastro_id, v_categoria_id, v_status_indexacao
  FROM private.base_conhecimento bc
  WHERE bc.id = p_documento_id
    AND bc.status_processamento = 'processado'
    AND bc.documento IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bc.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para enfileirar chunks: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;

  IF v_status_indexacao IS DISTINCT FROM 'indexando' THEN
    RAISE EXCEPTION 'Documento nao esta em indexacao: id %', p_documento_id
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM private.base_conhecimento_chunks bcc
  WHERE bcc.base_conhecimento_id = p_documento_id;

  DELETE FROM private.base_conhecimento_chunks_pendentes bcp
  WHERE bcp.base_conhecimento_id = p_documento_id;

  INSERT INTO private.base_conhecimento_chunks_pendentes (
    base_conhecimento_id,
    cadastro_id,
    categoria_id,
    chunk_index,
    conteudo,
    conteudo_hash,
    token_count
  )
  SELECT
    p_documento_id,
    v_cadastro_id,
    v_categoria_id,
    item.chunk_index,
    item.conteudo,
    item.conteudo_hash,
    item.token_count
  FROM jsonb_to_recordset(p_chunks) AS item (
    chunk_index integer,
    conteudo text,
    conteudo_hash text,
    token_count integer
  );

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows;
END;
$$;

ALTER FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_token_s2s text
) RETURNS TABLE (
  id uuid,
  documento_id uuid,
  chunk_index integer,
  conteudo text,
  conteudo_hash text,
  token_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'indexar_base_conhecimento');

  IF p_documento_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, false);

  RETURN QUERY
  SELECT
    bcp.id,
    bcp.base_conhecimento_id,
    bcp.chunk_index,
    bcp.conteudo,
    bcp.conteudo_hash,
    bcp.token_count
  FROM private.base_conhecimento_chunks_pendentes bcp
  INNER JOIN private.base_conhecimento bc
    ON bc.id = bcp.base_conhecimento_id
  WHERE bcp.base_conhecimento_id = p_documento_id
    AND bcp.status = 'pendente'
    AND bc.status_processamento = 'processado'
    AND bc.status_indexacao = 'indexando'
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bcp.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    )
  ORDER BY bcp.chunk_index;
END;
$$;

ALTER FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(
  p_chunk_pendente_id uuid,
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_embedding jsonb,
  p_embedding_model text,
  p_token_s2s text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_cadastro_id uuid;
  v_categoria_id uuid;
  v_chunk_index integer;
  v_conteudo text;
  v_conteudo_hash text;
  v_token_count integer;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'indexar_base_conhecimento');

  IF p_chunk_pendente_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: chunk_pendente_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_documento_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_embedding IS NULL OR jsonb_typeof(p_embedding) <> 'array' THEN
    RAISE EXCEPTION 'Parametro invalido: embedding deve ser um array.'
      USING ERRCODE = '22023';
  END IF;

  IF p_embedding_model IS NULL OR btrim(p_embedding_model) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: embedding_model.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, false);

  SELECT
    bcp.cadastro_id,
    bcp.categoria_id,
    bcp.chunk_index,
    bcp.conteudo,
    bcp.conteudo_hash,
    bcp.token_count
  INTO
    v_cadastro_id,
    v_categoria_id,
    v_chunk_index,
    v_conteudo,
    v_conteudo_hash,
    v_token_count
  FROM private.base_conhecimento_chunks_pendentes bcp
  INNER JOIN private.base_conhecimento bc
    ON bc.id = bcp.base_conhecimento_id
  WHERE bcp.id = p_chunk_pendente_id
    AND bcp.base_conhecimento_id = p_documento_id
    AND bcp.status = 'pendente'
    AND bc.status_processamento = 'processado'
    AND bc.status_indexacao = 'indexando'
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bcp.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chunk pendente nao encontrado para salvar embedding: id %', p_chunk_pendente_id
      USING ERRCODE = '02000';
  END IF;

  INSERT INTO private.base_conhecimento_chunks (
    base_conhecimento_id,
    cadastro_id,
    categoria_id,
    chunk_index,
    conteudo,
    conteudo_hash,
    embedding,
    embedding_model,
    token_count
  ) VALUES (
    p_documento_id,
    v_cadastro_id,
    v_categoria_id,
    v_chunk_index,
    v_conteudo,
    v_conteudo_hash,
    p_embedding::text::extensions.vector(384),
    p_embedding_model,
    v_token_count
  )
  ON CONFLICT (base_conhecimento_id, chunk_index)
  DO UPDATE SET
    conteudo = EXCLUDED.conteudo,
    conteudo_hash = EXCLUDED.conteudo_hash,
    embedding = EXCLUDED.embedding,
    embedding_model = EXCLUDED.embedding_model,
    token_count = EXCLUDED.token_count;

  UPDATE private.base_conhecimento_chunks_pendentes bcp
  SET
    status = 'concluido',
    tentativas = bcp.tentativas + 1,
    erro = NULL,
    embedding_model = p_embedding_model
  WHERE bcp.id = p_chunk_pendente_id;
END;
$$;

ALTER FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_chunk_pendente_indexado_s2s(uuid, uuid, uuid, jsonb, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_chunks jsonb,
  p_token_s2s text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_cadastro_id uuid;
  v_categoria_id uuid;
  v_status_indexacao text;
  v_rows integer := 0;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'indexar_base_conhecimento');

  IF p_documento_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_chunks IS NULL OR jsonb_typeof(p_chunks) <> 'array' OR jsonb_array_length(p_chunks) = 0 THEN
    RAISE EXCEPTION 'Parametro invalido: chunks deve ser um array nao vazio.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, false);

  SELECT bc.cadastro_id, bc.area_empresa, bc.status_indexacao
    INTO v_cadastro_id, v_categoria_id, v_status_indexacao
  FROM private.base_conhecimento bc
  WHERE bc.id = p_documento_id
    AND bc.status_processamento = 'processado'
    AND bc.documento IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bc.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para salvar chunks: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;

  IF v_status_indexacao IS DISTINCT FROM 'indexando' THEN
    RAISE EXCEPTION 'Documento nao esta em indexacao: id %', p_documento_id
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM private.base_conhecimento_chunks bcc
  WHERE bcc.base_conhecimento_id = p_documento_id;

  DELETE FROM private.base_conhecimento_chunks_pendentes bcp
  WHERE bcp.base_conhecimento_id = p_documento_id;

  INSERT INTO private.base_conhecimento_chunks (
    base_conhecimento_id,
    cadastro_id,
    categoria_id,
    chunk_index,
    conteudo,
    conteudo_hash,
    embedding,
    embedding_model,
    token_count
  )
  SELECT
    p_documento_id,
    v_cadastro_id,
    v_categoria_id,
    item.chunk_index,
    item.conteudo,
    item.conteudo_hash,
    item.embedding::text::extensions.vector(384),
    item.embedding_model,
    item.token_count
  FROM jsonb_to_recordset(p_chunks) AS item (
    chunk_index integer,
    conteudo text,
    conteudo_hash text,
    embedding jsonb,
    embedding_model text,
    token_count integer
  );

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows;
END;
$$;

ALTER FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text)
  OWNER TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(
  p_id uuid,
  p_auth_user_id uuid,
  p_status_indexacao text,
  p_qtd_chunks integer,
  p_embedding_model text,
  p_erro_indexacao text,
  p_token_s2s text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_rows integer := 0;
  v_chunks_salvos integer := 0;
  v_modelos_salvos integer := 0;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'indexar_base_conhecimento');

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_status_indexacao NOT IN ('indexado', 'erro') THEN
    RAISE EXCEPTION 'Status invalido para finalizacao da indexacao: %. Use indexado ou erro.', p_status_indexacao
      USING ERRCODE = '22023';
  END IF;

  IF p_status_indexacao = 'indexado'
     AND (p_qtd_chunks IS NULL OR p_qtd_chunks <= 0) THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: qtd_chunks para status indexado.'
      USING ERRCODE = '23502';
  END IF;

  IF p_status_indexacao = 'indexado'
     AND (p_embedding_model IS NULL OR btrim(p_embedding_model) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: embedding_model para status indexado.'
      USING ERRCODE = '23502';
  END IF;

  IF p_status_indexacao = 'erro'
     AND (p_erro_indexacao IS NULL OR btrim(p_erro_indexacao) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: erro_indexacao para status erro.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, false);

  PERFORM 1
  FROM private.base_conhecimento bc
  WHERE bc.id = p_id
    AND bc.status_processamento = 'processado'
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bc.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para finalizar indexacao: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  IF p_status_indexacao = 'indexado' THEN
    SELECT
      count(*)::integer,
      count(DISTINCT bcc.embedding_model)::integer
      INTO v_chunks_salvos, v_modelos_salvos
    FROM private.base_conhecimento_chunks bcc
    WHERE bcc.base_conhecimento_id = p_id;

    IF v_chunks_salvos IS DISTINCT FROM p_qtd_chunks THEN
      RAISE EXCEPTION 'Quantidade de chunks inconsistente para o documento %: esperado %, salvo %.',
        p_id, p_qtd_chunks, v_chunks_salvos
        USING ERRCODE = '22023';
    END IF;

    IF v_modelos_salvos IS DISTINCT FROM 1
       OR EXISTS (
         SELECT 1
         FROM private.base_conhecimento_chunks bcc
         WHERE bcc.base_conhecimento_id = p_id
           AND bcc.embedding_model IS DISTINCT FROM p_embedding_model
       ) THEN
      RAISE EXCEPTION 'Modelo de embedding inconsistente para o documento %.', p_id
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE private.base_conhecimento bc
  SET
    status_indexacao = p_status_indexacao,
    indexado_em = CASE
      WHEN p_status_indexacao = 'indexado' THEN now()
      ELSE NULL
    END,
    qtd_chunks = CASE
      WHEN p_status_indexacao = 'indexado' THEN p_qtd_chunks
      ELSE NULL
    END,
    embedding_model = CASE
      WHEN p_status_indexacao = 'indexado' THEN p_embedding_model
      ELSE NULL
    END,
    erro_indexacao = CASE
      WHEN p_status_indexacao = 'erro' THEN p_erro_indexacao
      ELSE NULL
    END
  WHERE bc.id = p_id
    AND bc.status_processamento = 'processado'
    AND EXISTS (
      SELECT 1
      FROM private.cadastro c
      WHERE c.id = bc.cadastro_id
        AND c.auth_user_id = p_auth_user_id
    );

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para finalizar indexacao: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  IF p_status_indexacao = 'indexado' THEN
    DELETE FROM private.base_conhecimento_chunks_pendentes bcp
    WHERE bcp.base_conhecimento_id = p_id;
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text)
  OWNER TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;