-- RPCs S2S de processamento, indexacao e busca da base de conhecimento.
-- Depende da migration 20260619162000, que cria as RPCs administrativas.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
-- ---------------------------------------------------------------------------
-- Helpers de acesso S2S para processamento/indexacao.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.auth_user_can_process_kb_document(uuid, uuid);

CREATE OR REPLACE FUNCTION private.auth_user_can_process_kb_document(
  p_documento_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  WITH subject AS (
    SELECT private.get_session_auth_user_id() AS auth_user_id
  )
  SELECT EXISTS (
    SELECT 1
    FROM subject s
    INNER JOIN private.base_conhecimento bc ON bc.id = p_documento_id
    WHERE s.auth_user_id IS NOT NULL
      AND bc.cadastro_id IS NULL
      AND private.auth_user_has_admin_profile(s.auth_user_id, 'admin_docs')
      AND (
        bc.tags @> ARRAY['publico']::text[]
        OR bc.tags @> ARRAY['default_elo']::text[]
      )
  );
$$;

ALTER FUNCTION private.auth_user_can_process_kb_document(uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.auth_user_can_process_kb_document(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.auth_user_can_process_kb_document(uuid) FROM anon;
REVOKE ALL ON FUNCTION private.auth_user_can_process_kb_document(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION private.auth_user_can_process_kb_document(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION private.auth_user_can_process_kb_document(uuid)
  TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- Somente documentos globais administrados pela Elo sao processados.
-- Trigger/processamento de PDF: suporta documentos de sistema com admin_docs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.notificar_n8n_processar_base_conhecimento()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
DECLARE
  v_auth_user_id uuid;
  v_categoria_nome text;
BEGIN
  IF TG_NAME IS DISTINCT FROM 'trg_base_conhecimento_notificar_n8n_processamento'
     OR TG_WHEN IS DISTINCT FROM 'BEFORE'
     OR TG_OP IS DISTINCT FROM 'INSERT'
     OR TG_TABLE_SCHEMA IS DISTINCT FROM 'private'
     OR TG_TABLE_NAME IS DISTINCT FROM 'base_conhecimento' THEN
    RAISE EXCEPTION 'Acesso negado: funcao deve ser executada somente pelo trigger da base de conhecimento.'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status_processamento IS DISTINCT FROM 'processando'
     OR NEW.url_documento IS NULL
     OR NEW.documento IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT cat.nome INTO v_categoria_nome
  FROM private.categorias cat
  WHERE cat.id = NEW.area_empresa;

  IF NEW.cadastro_id IS NOT NULL THEN
    RAISE EXCEPTION 'A Elo processa somente documentos globais enviados pelo painel administrativo.'
      USING ERRCODE = '42501';
  END IF;

  v_auth_user_id := NEW.criado_por_auth_user_id;

  IF v_auth_user_id IS NULL
     OR private.auth_user_has_admin_profile(v_auth_user_id, 'admin_docs') IS NOT TRUE
     OR NOT (
       NEW.tags @> ARRAY['publico']::text[]
       OR NEW.tags @> ARRAY['default_elo']::text[]
     )
  THEN
    RAISE EXCEPTION 'Documento global precisa de admin_docs e tag publica/default para processamento.'
      USING ERRCODE = '42501';
  END IF;

  PERFORM private.dispatch_base_conhecimento_webhook(
    p_documento_id := NEW.id,
    p_cadastro_id := NEW.cadastro_id,
    p_auth_user_id := v_auth_user_id,
    p_tipo_relatorio := NEW.tipo_relatorio,
    p_categoria_id := NEW.area_empresa,
    p_categoria_nome := v_categoria_nome,
    p_url_documento := NEW.url_documento,
    p_status_processamento := NEW.status_processamento,
    p_created_at := NEW.hora_criacao,
    p_origem := NULL
  );

  RETURN NEW;
END;
$$;

ALTER FUNCTION private.notificar_n8n_processar_base_conhecimento() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.notificar_n8n_processar_base_conhecimento() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.notificar_n8n_processar_base_conhecimento() FROM anon;
REVOKE ALL ON FUNCTION private.notificar_n8n_processar_base_conhecimento() FROM authenticated;
REVOKE ALL ON FUNCTION private.notificar_n8n_processar_base_conhecimento() FROM service_role;

DROP TRIGGER IF EXISTS trg_base_conhecimento_notificar_n8n_processamento ON private.base_conhecimento;
CREATE TRIGGER trg_base_conhecimento_notificar_n8n_processamento
BEFORE INSERT ON private.base_conhecimento
FOR EACH ROW
WHEN (
  NEW.status_processamento = 'processando'
  AND NEW.url_documento IS NOT NULL
  AND NEW.documento IS NULL
)
EXECUTE FUNCTION private.notificar_n8n_processar_base_conhecimento();

CREATE OR REPLACE FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(
  p_id uuid,
  p_status_processamento text,
  p_auth_user_id uuid,
  p_token_s2s text,
  p_documento text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_rows integer := 0;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'processar_base_conhecimento');

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: auth_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_status_processamento NOT IN ('processado', 'erro') THEN
    RAISE EXCEPTION 'Status invalido para finalizacao: %. Use processado ou erro.', p_status_processamento
      USING ERRCODE = '22023';
  END IF;

  IF p_status_processamento = 'processado'
     AND (p_documento IS NULL OR btrim(p_documento) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento para status processado.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento nao encontrado para o auth_user_id informado: id %', p_id
      USING ERRCODE = '02000';
  END IF;


  UPDATE private.base_conhecimento bc
  SET
    documento = CASE
      WHEN p_status_processamento = 'processado' THEN private.encrypt_value(p_documento)
      ELSE bc.documento
    END,
    status_processamento = p_status_processamento,
    status_indexacao = CASE
      WHEN p_status_processamento = 'processado' THEN 'pendente'
      ELSE 'erro'
    END,
    erro_indexacao = CASE
      WHEN p_status_processamento = 'erro' THEN COALESCE(NULLIF(p_documento, ''), 'Erro no processamento do documento.')
      ELSE NULL
    END
  WHERE bc.id = p_id
    AND private.auth_user_can_process_kb_document(bc.id);

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento nao encontrado para atualizar: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_finalizar_processamento_documento_base_conhecimento(uuid, text, uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Indexacao S2S: criptografa chunks e aceita docs privados ou de sistema.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(
  p_id uuid,
  p_auth_user_id uuid,
  p_token_s2s text
) RETURNS TABLE (
  id uuid,
  documento text,
  cadastro_id uuid,
  categoria_id uuid,
  status_indexacao text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_rows integer := 0;
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

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para indexacao: id %', p_id
      USING ERRCODE = '02000';
  END IF;


  RETURN QUERY
  UPDATE private.base_conhecimento bc
  SET
    status_indexacao = 'indexando',
    indexado_em = NULL,
    qtd_chunks = NULL,
    embedding_model = NULL,
    erro_indexacao = NULL
  WHERE bc.id = p_id
    AND bc.status_processamento = 'processado'
    AND bc.documento IS NOT NULL
    AND private.auth_user_can_process_kb_document(bc.id)
  RETURNING
    bc.id,
    private.decrypt_value(bc.documento),
    bc.cadastro_id,
    bc.area_empresa,
    bc.status_indexacao;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para indexacao: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_iniciar_indexacao_documento_base_conhecimento(uuid, uuid, text) TO service_role;

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

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para salvar chunks: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  SELECT bc.cadastro_id, bc.area_empresa, bc.status_indexacao
    INTO v_cadastro_id, v_categoria_id, v_status_indexacao
  FROM private.base_conhecimento bc
  WHERE bc.id = p_documento_id
    AND bc.status_processamento = 'processado'
    AND bc.documento IS NOT NULL
    AND private.auth_user_can_process_kb_document(bc.id);

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
    private.encrypt_value(item.conteudo),
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
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_chunks_base_conhecimento_s2s(uuid, uuid, jsonb, text) TO service_role;

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

  IF v_qtd_chunks <= 80 THEN
    RAISE EXCEPTION 'Fila pendente reservada para documentos com mais de 80 chunks: recebido %.', v_qtd_chunks
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para enfileirar chunks: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  SELECT bc.cadastro_id, bc.area_empresa, bc.status_indexacao
    INTO v_cadastro_id, v_categoria_id, v_status_indexacao
  FROM private.base_conhecimento bc
  WHERE bc.id = p_documento_id
    AND bc.status_processamento = 'processado'
    AND bc.documento IS NOT NULL
    AND private.auth_user_can_process_kb_document(bc.id);

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
    private.encrypt_value(item.conteudo),
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
GRANT EXECUTE ON FUNCTION public.rpc_enfileirar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, jsonb, text) TO service_role;

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

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para listar chunks pendentes: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  RETURN QUERY
  SELECT
    bcp.id,
    bcp.base_conhecimento_id,
    bcp.chunk_index,
    private.decrypt_value(bcp.conteudo),
    bcp.conteudo_hash,
    bcp.token_count
  FROM private.base_conhecimento_chunks_pendentes bcp
  INNER JOIN private.base_conhecimento bc
    ON bc.id = bcp.base_conhecimento_id
  WHERE bcp.base_conhecimento_id = p_documento_id
    AND bcp.status = 'pendente'
    AND bc.status_processamento = 'processado'
    AND bc.status_indexacao = 'indexando'
    AND private.auth_user_can_process_kb_document(bc.id)
  ORDER BY bcp.chunk_index
  LIMIT 100;
END;
$$;

ALTER FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_listar_chunks_pendentes_base_conhecimento_s2s(uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_chunks jsonb,
  p_embedding_model text,
  p_token_s2s text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_total_input integer;
  v_total_shape_valid integer;
  v_total_distintos integer;
  v_total_validos integer;
  v_total_upserted integer;
  v_total_salvos integer;
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

  IF p_embedding_model IS NULL OR btrim(p_embedding_model) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: embedding_model.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para salvar lote de chunks: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  WITH input_chunks AS MATERIALIZED (
    SELECT item.chunk_pendente_id, item.embedding
    FROM jsonb_to_recordset(p_chunks) AS item (
      chunk_pendente_id uuid,
      embedding jsonb
    )
  ),
  shape_stats AS MATERIALIZED (
    SELECT
      COUNT(*)::integer AS total_input,
      COUNT(*) FILTER (
        WHERE input.chunk_pendente_id IS NOT NULL
          AND input.embedding IS NOT NULL
          AND CASE
            WHEN jsonb_typeof(input.embedding) = 'array'
              THEN jsonb_array_length(input.embedding)
            ELSE NULL
          END = 384
      )::integer AS total_shape_valid,
      COUNT(DISTINCT input.chunk_pendente_id) FILTER (
        WHERE input.chunk_pendente_id IS NOT NULL
          AND input.embedding IS NOT NULL
          AND CASE
            WHEN jsonb_typeof(input.embedding) = 'array'
              THEN jsonb_array_length(input.embedding)
            ELSE NULL
          END = 384
      )::integer AS total_distintos
    FROM input_chunks input
  ),
  valid_chunks AS MATERIALIZED (
    SELECT
      input.chunk_pendente_id,
      input.embedding,
      bcp.cadastro_id,
      bcp.categoria_id,
      bcp.chunk_index,
      private.decrypt_value(bcp.conteudo) AS conteudo_plain,
      bcp.conteudo_hash,
      bcp.token_count
    FROM input_chunks input
    INNER JOIN private.base_conhecimento_chunks_pendentes bcp
      ON bcp.id = input.chunk_pendente_id
    INNER JOIN private.base_conhecimento bc
      ON bc.id = bcp.base_conhecimento_id
    WHERE input.chunk_pendente_id IS NOT NULL
      AND input.embedding IS NOT NULL
      AND CASE
        WHEN jsonb_typeof(input.embedding) = 'array'
          THEN jsonb_array_length(input.embedding)
        ELSE NULL
      END = 384
      AND bcp.base_conhecimento_id = p_documento_id
      AND bcp.status = 'pendente'
      AND bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexando'
      AND private.auth_user_can_process_kb_document(bc.id)
  ),
  business_stats AS MATERIALIZED (
    SELECT COUNT(*)::integer AS total_validos
    FROM valid_chunks
  ),
  validation AS (
    SELECT
      shape_stats.total_input,
      shape_stats.total_shape_valid,
      shape_stats.total_distintos,
      business_stats.total_validos,
      (
        shape_stats.total_input = jsonb_array_length(p_chunks)
        AND shape_stats.total_shape_valid = shape_stats.total_input
        AND shape_stats.total_distintos = shape_stats.total_input
        AND business_stats.total_validos = shape_stats.total_input
      ) AS pode_gravar
    FROM shape_stats
    CROSS JOIN business_stats
  ),
  upserted AS (
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
      vc.cadastro_id,
      vc.categoria_id,
      vc.chunk_index,
      private.encrypt_value(vc.conteudo_plain),
      vc.conteudo_hash,
      vc.embedding::text::extensions.vector(384),
      p_embedding_model,
      vc.token_count
    FROM valid_chunks vc
    WHERE (SELECT pode_gravar FROM validation)
    ON CONFLICT (base_conhecimento_id, chunk_index)
    DO UPDATE SET
      conteudo = EXCLUDED.conteudo,
      conteudo_hash = EXCLUDED.conteudo_hash,
      embedding = EXCLUDED.embedding,
      embedding_model = EXCLUDED.embedding_model,
      token_count = EXCLUDED.token_count
    RETURNING chunk_index
  ),
  updated AS (
    UPDATE private.base_conhecimento_chunks_pendentes bcp
    SET
      status = 'concluido',
      tentativas = bcp.tentativas + 1,
      erro = NULL,
      embedding_model = p_embedding_model
    FROM valid_chunks vc
    WHERE bcp.id = vc.chunk_pendente_id
      AND (SELECT pode_gravar FROM validation)
    RETURNING bcp.id
  )
  SELECT
    (SELECT total_input FROM validation),
    (SELECT total_shape_valid FROM validation),
    (SELECT total_distintos FROM validation),
    (SELECT total_validos FROM validation),
    (SELECT COUNT(*) FROM upserted),
    (SELECT COUNT(*) FROM updated)
    INTO
      v_total_input,
      v_total_shape_valid,
      v_total_distintos,
      v_total_validos,
      v_total_upserted,
      v_total_salvos;

  IF v_total_input <> jsonb_array_length(p_chunks) OR v_total_shape_valid <> v_total_input THEN
    RAISE EXCEPTION 'Parametro invalido: todos os chunks devem conter chunk_pendente_id e embedding array com 384 dimensoes.'
      USING ERRCODE = '22023';
  END IF;

  IF v_total_distintos <> v_total_input THEN
    RAISE EXCEPTION 'Parametro invalido: existem chunk_pendente_id duplicados no lote.'
      USING ERRCODE = '22023';
  END IF;

  IF v_total_validos <> v_total_input THEN
    RAISE EXCEPTION 'Um ou mais chunks pendentes nao pertencem ao documento/usuario informado ou nao estao pendentes.'
      USING ERRCODE = '02000';
  END IF;

  IF v_total_upserted <> v_total_input OR v_total_salvos <> v_total_input THEN
    RAISE EXCEPTION 'Falha ao salvar lote completo de chunks pendentes.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_total_salvos;
END;
$$;

ALTER FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text) TO service_role;

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

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_id) IS NOT TRUE THEN
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
    indexado_em = CASE WHEN p_status_indexacao = 'indexado' THEN now() ELSE NULL END,
    qtd_chunks = CASE WHEN p_status_indexacao = 'indexado' THEN p_qtd_chunks ELSE NULL END,
    embedding_model = CASE WHEN p_status_indexacao = 'indexado' THEN p_embedding_model ELSE NULL END,
    erro_indexacao = CASE WHEN p_status_indexacao = 'erro' THEN p_erro_indexacao ELSE NULL END
  WHERE bc.id = p_id
    AND bc.status_processamento = 'processado'
    AND private.auth_user_can_process_kb_document(bc.id);

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento processado nao encontrado para finalizar indexacao: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_finalizar_indexacao_documento_base_conhecimento(uuid, uuid, text, integer, text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_token_s2s text,
  p_limite_total integer DEFAULT 15
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_limite integer := COALESCE(p_limite_total, 15);
  v_result jsonb;
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

  IF v_limite < 3 OR v_limite > 30 THEN
    RAISE EXCEPTION 'Parametro invalido: limite_total deve estar entre 3 e 30.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento indexado nao encontrado para amostra: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  WITH documento AS (
    SELECT
      bc.id,
      bc.cadastro_id,
      bc.area_empresa AS categoria_id,
      cat.nome AS categoria_nome,
      COALESCE(bc.qtd_chunks, 0)::integer AS qtd_chunks,
      bc.embedding_model,
      bc.status_processamento,
      bc.status_indexacao
    FROM private.base_conhecimento bc
    LEFT JOIN private.categorias cat ON cat.id = bc.area_empresa
    WHERE bc.id = p_documento_id
      AND bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexado'
      AND private.auth_user_can_process_kb_document(bc.id)
  ),
  amostra_config AS (
    SELECT
      d.*,
      ceil(v_limite::numeric / 3)::integer AS qtd_inicio,
      floor(v_limite::numeric / 3)::integer AS qtd_fim,
      (
        v_limite
        - ceil(v_limite::numeric / 3)::integer
        - floor(v_limite::numeric / 3)::integer
      ) AS qtd_meio,
      ((d.qtd_chunks - 1) / 2)::integer AS centro
    FROM documento d
  ),
  indices_amostra AS (
    SELECT gs.idx
    FROM amostra_config ac
    CROSS JOIN LATERAL generate_series(0, ac.qtd_chunks - 1) AS gs(idx)
    WHERE ac.qtd_chunks > 0
      AND ac.qtd_chunks <= v_limite

    UNION

    SELECT gs.idx
    FROM amostra_config ac
    CROSS JOIN LATERAL generate_series(0, LEAST(ac.qtd_inicio - 1, ac.qtd_chunks - 1)) AS gs(idx)
    WHERE ac.qtd_chunks > v_limite

    UNION

    SELECT gs.idx
    FROM amostra_config ac
    CROSS JOIN LATERAL generate_series(
      GREATEST(0, ac.centro - floor(ac.qtd_meio::numeric / 2)::integer),
      LEAST(
        ac.qtd_chunks - 1,
        GREATEST(0, ac.centro - floor(ac.qtd_meio::numeric / 2)::integer) + ac.qtd_meio - 1
      )
    ) AS gs(idx)
    WHERE ac.qtd_chunks > v_limite
      AND ac.qtd_meio > 0

    UNION

    SELECT gs.idx
    FROM amostra_config ac
    CROSS JOIN LATERAL generate_series(GREATEST(0, ac.qtd_chunks - ac.qtd_fim), ac.qtd_chunks - 1) AS gs(idx)
    WHERE ac.qtd_chunks > v_limite
      AND ac.qtd_fim > 0
  ),
  indices_limitados AS (
    SELECT DISTINCT ia.idx
    FROM indices_amostra ia
    ORDER BY ia.idx
    LIMIT v_limite
  ),
  chunks_amostra AS (
    SELECT bcc.chunk_index, private.decrypt_value(bcc.conteudo) AS conteudo
    FROM documento d
    INNER JOIN indices_limitados il ON TRUE
    INNER JOIN private.base_conhecimento_chunks bcc
      ON bcc.base_conhecimento_id = d.id
     AND bcc.chunk_index = il.idx
    ORDER BY bcc.chunk_index
  )
  SELECT jsonb_build_object(
    'documento_id', d.id,
    'cadastro_id', d.cadastro_id,
    'categoria_id', d.categoria_id,
    'categoria_nome', d.categoria_nome,
    'qtd_chunks', d.qtd_chunks,
    'embedding_model', d.embedding_model,
    'chunks_amostra', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'chunk_index', ca.chunk_index,
            'conteudo', ca.conteudo
          )
          ORDER BY ca.chunk_index
        )
        FROM chunks_amostra ca
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM documento d;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Documento indexado nao encontrado para amostra: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_obter_amostra_documento_base_conhecimento_s2s(uuid, uuid, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  p_documento_id uuid,
  p_auth_user_id uuid,
  p_titulo_detectado text,
  p_tipo_documento text,
  p_resumo_busca text,
  p_assuntos_json jsonb,
  p_entidades_json jsonb,
  p_embedding_resumo jsonb,
  p_embedding_model text,
  p_token_count integer,
  p_token_s2s text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_cadastro_id uuid;
  v_categoria_id uuid;
  v_indice_id uuid;
  v_indice_hash text;
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

  IF p_resumo_busca IS NULL OR btrim(p_resumo_busca) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: resumo_busca.'
      USING ERRCODE = '23502';
  END IF;

  IF p_embedding_resumo IS NULL OR jsonb_typeof(p_embedding_resumo) <> 'array' THEN
    RAISE EXCEPTION 'Parametro invalido: embedding_resumo deve ser um array.'
      USING ERRCODE = '22023';
  END IF;

  IF p_embedding_model IS NULL OR btrim(p_embedding_model) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: embedding_model.'
      USING ERRCODE = '23502';
  END IF;

  IF p_token_count IS NULL OR p_token_count <= 0 THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: token_count.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_auth_user_id', p_auth_user_id::text, true);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  IF private.auth_user_can_process_kb_document(p_documento_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Documento indexado nao encontrado para gerar indice contextual: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;


  SELECT bc.cadastro_id, bc.area_empresa
    INTO v_cadastro_id, v_categoria_id
  FROM private.base_conhecimento bc
  WHERE bc.id = p_documento_id
    AND bc.status_processamento = 'processado'
    AND bc.status_indexacao = 'indexado'
    AND private.auth_user_can_process_kb_document(bc.id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento indexado nao encontrado para gerar indice contextual: id %', p_documento_id
      USING ERRCODE = '02000';
  END IF;

  v_indice_hash := private.hash_value(
    COALESCE(p_titulo_detectado, '') || '|' ||
    COALESCE(p_tipo_documento, '') || '|' ||
    p_resumo_busca || '|' ||
    COALESCE(p_assuntos_json::text, '') || '|' ||
    COALESCE(p_entidades_json::text, '')
  );

  INSERT INTO private.base_conhecimento_documentos_indice (
    base_conhecimento_id,
    cadastro_id,
    categoria_id,
    titulo_detectado_enc,
    tipo_documento,
    resumo_busca_enc,
    assuntos_json_enc,
    entidades_json_enc,
    embedding_resumo,
    embedding_model,
    token_count,
    indice_hash,
    indexado_em
  ) VALUES (
    p_documento_id,
    v_cadastro_id,
    v_categoria_id,
    CASE
      WHEN p_titulo_detectado IS NULL OR btrim(p_titulo_detectado) = '' THEN NULL
      ELSE private.encrypt_value(p_titulo_detectado)
    END,
    NULLIF(btrim(p_tipo_documento), ''),
    private.encrypt_value(p_resumo_busca),
    private.encrypt_value(COALESCE(p_assuntos_json, '[]'::jsonb)::text),
    private.encrypt_value(COALESCE(p_entidades_json, '{}'::jsonb)::text),
    p_embedding_resumo::text::extensions.vector(384),
    p_embedding_model,
    p_token_count,
    v_indice_hash,
    now()
  )
  ON CONFLICT (base_conhecimento_id) DO UPDATE
  SET
    cadastro_id = EXCLUDED.cadastro_id,
    categoria_id = EXCLUDED.categoria_id,
    titulo_detectado_enc = EXCLUDED.titulo_detectado_enc,
    tipo_documento = EXCLUDED.tipo_documento,
    resumo_busca_enc = EXCLUDED.resumo_busca_enc,
    assuntos_json_enc = EXCLUDED.assuntos_json_enc,
    entidades_json_enc = EXCLUDED.entidades_json_enc,
    embedding_resumo = EXCLUDED.embedding_resumo,
    embedding_model = EXCLUDED.embedding_model,
    token_count = EXCLUDED.token_count,
    indice_hash = EXCLUDED.indice_hash,
    indexado_em = now()
  RETURNING id INTO v_indice_id;

  RETURN v_indice_id;
END;
$$;

ALTER FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_indice_documento_base_conhecimento_s2s(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, text, integer, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  p_wa_user_id text,
  p_embedding_pergunta extensions.vector(384),
  p_top_k integer DEFAULT 20,
  p_sessao_token text DEFAULT NULL,
  p_token_s2s text DEFAULT NULL,
  p_pergunta_busca text DEFAULT NULL,
  p_documento_ativo_id uuid DEFAULT NULL,
  p_usar_documento_ativo boolean DEFAULT false,
  p_top_documentos integer DEFAULT 3,
  p_chunks_por_documento integer DEFAULT 6,
  p_vizinhos integer DEFAULT 1,
  p_score_min_documento_candidato double precision DEFAULT 0.70,
  p_chunks_documento_ativo integer DEFAULT NULL
) RETURNS TABLE (
  chunk_id uuid,
  base_conhecimento_id uuid,
  documento_titulo text,
  conteudo text,
  score double precision,
  score_documento double precision,
  categoria_id uuid,
  chunk_index integer,
  origem text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_top_k integer := COALESCE(p_top_k, 20);
  v_top_documentos integer := COALESCE(p_top_documentos, 3);
  v_chunks_por_documento integer := COALESCE(p_chunks_por_documento, 6);
  v_vizinhos integer := COALESCE(p_vizinhos, 1);
  v_chunks_documento_ativo integer := COALESCE(p_chunks_documento_ativo, LEAST(COALESCE(p_chunks_por_documento, 6) * 2, 20));
  v_score_min_documento_candidato double precision := COALESCE(p_score_min_documento_candidato, 0.70);
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  PERFORM NULLIF(btrim(p_pergunta_busca), '');

  IF p_embedding_pergunta IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: embedding_pergunta.'
      USING ERRCODE = '23502';
  END IF;

  IF v_top_k < 1 OR v_top_k > 80 THEN
    RAISE EXCEPTION 'Parametro invalido: top_k deve estar entre 1 e 80.'
      USING ERRCODE = '22023';
  END IF;

  IF v_top_documentos < 1 OR v_top_documentos > 10 THEN
    RAISE EXCEPTION 'Parametro invalido: top_documentos deve estar entre 1 e 10.'
      USING ERRCODE = '22023';
  END IF;

  IF v_chunks_por_documento < 1 OR v_chunks_por_documento > 20 THEN
    RAISE EXCEPTION 'Parametro invalido: chunks_por_documento deve estar entre 1 e 20.'
      USING ERRCODE = '22023';
  END IF;

  IF v_chunks_documento_ativo < 1 OR v_chunks_documento_ativo > 20 THEN
    RAISE EXCEPTION 'Parametro invalido: chunks_documento_ativo deve estar entre 1 e 20.'
      USING ERRCODE = '22023';
  END IF;

  IF v_vizinhos < 0 OR v_vizinhos > 3 THEN
    RAISE EXCEPTION 'Parametro invalido: vizinhos deve estar entre 0 e 3.'
      USING ERRCODE = '22023';
  END IF;

  IF v_score_min_documento_candidato < -1 OR v_score_min_documento_candidato > 1 THEN
    RAISE EXCEPTION 'Parametro invalido: score_min_documento_candidato deve estar entre -1 e 1.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  PERFORM set_config('app.session_base_conhecimento_default_validated', 'true', true);
  PERFORM set_config('app.session_base_conhecimento_publica_validated', 'true', true);

  RETURN QUERY
  WITH allowed_docs AS MATERIALIZED (
    SELECT bc.id, bc.area_empresa AS categoria_id, bc.tags
    FROM private.base_conhecimento bc
    WHERE bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexado'
      AND bc.cadastro_id IS NULL
      AND (
        bc.tags @> ARRAY['publico']::text[]
        OR bc.tags @> ARRAY['default_elo']::text[]
      )
  ),
  documentos_semanticos AS (
    SELECT
      bcdi.base_conhecimento_id,
      bcdi.categoria_id,
      CASE
        WHEN bcdi.titulo_detectado_enc IS NULL THEN NULL
        ELSE private.decrypt_value(bcdi.titulo_detectado_enc)
      END AS titulo_detectado,
      1 - (bcdi.embedding_resumo <=> p_embedding_pergunta) AS score_documento,
      CASE
        WHEN p_usar_documento_ativo IS TRUE
          AND p_documento_ativo_id IS NOT NULL
          AND bcdi.base_conhecimento_id = p_documento_ativo_id
        THEN 'documento_ativo'
        ELSE 'documento_semantico'
      END AS origem_documento
    FROM private.base_conhecimento_documentos_indice bcdi
    INNER JOIN allowed_docs ad ON ad.id = bcdi.base_conhecimento_id
    WHERE p_usar_documento_ativo IS NOT TRUE
      OR p_documento_ativo_id IS NULL
      OR bcdi.base_conhecimento_id = p_documento_ativo_id
      OR (1 - (bcdi.embedding_resumo <=> p_embedding_pergunta)) >= v_score_min_documento_candidato
    ORDER BY
      CASE
        WHEN p_usar_documento_ativo IS TRUE
          AND p_documento_ativo_id IS NOT NULL
          AND bcdi.base_conhecimento_id = p_documento_ativo_id
        THEN 0
        ELSE 1
      END,
      bcdi.embedding_resumo <=> p_embedding_pergunta,
      bcdi.base_conhecimento_id
    LIMIT v_top_documentos
  ),
  doc_chunks AS (
    SELECT
      bcc.id AS chunk_id,
      bcc.base_conhecimento_id,
      ds.titulo_detectado,
      private.decrypt_value(bcc.conteudo) AS conteudo,
      1 - (bcc.embedding <=> p_embedding_pergunta) AS score_chunk,
      ds.score_documento,
      bcc.categoria_id,
      bcc.chunk_index,
      ds.origem_documento,
      row_number() OVER (
        PARTITION BY bcc.base_conhecimento_id
        ORDER BY
          CASE
            WHEN p_usar_documento_ativo IS TRUE
              AND p_documento_ativo_id IS NOT NULL
              AND bcc.base_conhecimento_id = p_documento_ativo_id
            THEN bcc.embedding <=> p_embedding_pergunta
            ELSE bcc.embedding <=> p_embedding_pergunta
          END,
          bcc.chunk_index
      ) AS rn_documento
    FROM documentos_semanticos ds
    INNER JOIN private.base_conhecimento_chunks bcc
      ON bcc.base_conhecimento_id = ds.base_conhecimento_id
  ),
  semantic_limited AS (
    SELECT *
    FROM doc_chunks dc
    WHERE dc.rn_documento <= CASE
      WHEN p_usar_documento_ativo IS TRUE
        AND p_documento_ativo_id IS NOT NULL
        AND dc.base_conhecimento_id = p_documento_ativo_id
      THEN v_chunks_documento_ativo
      ELSE v_chunks_por_documento
    END
  ),
  fallback_chunks AS (
    SELECT
      bcc.id AS chunk_id,
      bcc.base_conhecimento_id,
      NULL::text AS titulo_detectado,
      private.decrypt_value(bcc.conteudo) AS conteudo,
      1 - (bcc.embedding <=> p_embedding_pergunta) AS score_chunk,
      NULL::double precision AS score_documento,
      bcc.categoria_id,
      bcc.chunk_index,
      CASE
        WHEN p_usar_documento_ativo IS TRUE
          AND p_documento_ativo_id IS NOT NULL
          AND bcc.base_conhecimento_id = p_documento_ativo_id
        THEN 'fallback_documento_ativo'
        ELSE 'fallback_chunks'
      END AS origem_documento,
      row_number() OVER (ORDER BY bcc.embedding <=> p_embedding_pergunta, bcc.id) AS rn
    FROM private.base_conhecimento_chunks bcc
    INNER JOIN allowed_docs ad ON ad.id = bcc.base_conhecimento_id
    WHERE NOT EXISTS (SELECT 1 FROM documentos_semanticos)
      AND (
        p_usar_documento_ativo IS NOT TRUE
        OR p_documento_ativo_id IS NULL
        OR bcc.base_conhecimento_id = p_documento_ativo_id
      )
  ),
  candidatos AS (
    SELECT
      sl.chunk_id,
      sl.base_conhecimento_id,
      sl.titulo_detectado,
      sl.conteudo,
      sl.score_chunk,
      sl.score_documento,
      sl.categoria_id,
      sl.chunk_index,
      sl.origem_documento
    FROM semantic_limited sl

    UNION ALL

    SELECT
      fc.chunk_id,
      fc.base_conhecimento_id,
      fc.titulo_detectado,
      fc.conteudo,
      fc.score_chunk,
      fc.score_documento,
      fc.categoria_id,
      fc.chunk_index,
      fc.origem_documento
    FROM fallback_chunks fc
    WHERE fc.rn <= v_top_k
  )
  SELECT
    c.chunk_id,
    c.base_conhecimento_id,
    c.titulo_detectado AS documento_titulo,
    c.conteudo,
    c.score_chunk AS score,
    c.score_documento,
    c.categoria_id,
    c.chunk_index,
    c.origem_documento AS origem
  FROM candidatos c
  ORDER BY
    CASE
      WHEN p_usar_documento_ativo IS TRUE
        AND p_documento_ativo_id IS NOT NULL
        AND c.base_conhecimento_id = p_documento_ativo_id
      THEN 0
      ELSE 1
    END,
    c.score_documento DESC NULLS LAST,
    c.score_chunk DESC,
    c.base_conhecimento_id,
    c.chunk_index
  LIMIT v_top_k;
END;
$$;

ALTER FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_s2s(
  text, extensions.vector, integer, text, text, text, uuid, boolean, integer, integer, integer, double precision, integer
) TO service_role;
