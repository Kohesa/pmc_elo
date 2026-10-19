-- RPCs administrativas para a base de conhecimento default/publica da Elo.
-- Depende da migration 20260619161000, que prepara schema, criptografia e RLS.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
-- ---------------------------------------------------------------------------
-- RPCs admin para base default/publica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_admin_kb_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT public.request_has_admin_profile('admin_docs');
$$;

ALTER FUNCTION public.rpc_admin_kb_is_admin() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_is_admin() FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_is_admin() FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_is_admin() FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_is_admin() TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_listar_categorias(
  p_escopo text DEFAULT NULL
) RETURNS TABLE (
  id uuid,
  nome text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  -- Mantem o contrato atual da tela; ambos os escopos usam as mesmas categorias.
  PERFORM private.normalizar_kb_admin_escopo(p_escopo);

  RETURN QUERY
  SELECT cat.id, cat.nome, cat.created_at, cat.updated_at
  FROM private.categorias cat
  WHERE cat.cadastro_id IS NULL
  ORDER BY cat.nome ASC, cat.created_at DESC, cat.id DESC;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_listar_categorias(text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_categorias(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_categorias(text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_categorias(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_categorias(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_listar_categorias(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_criar_categoria(
  p_nome text
) RETURNS TABLE (
  id uuid,
  nome text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_nome text := NULLIF(btrim(p_nome), '');
  v_categoria_id uuid;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF v_nome IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: nome.'
      USING ERRCODE = '23502';
  END IF;

  v_categoria_id := private.get_or_create_categoria_base_conhecimento(NULL, v_nome);

  RETURN QUERY
  SELECT cat.id, cat.nome, cat.created_at, cat.updated_at
  FROM private.categorias cat
  WHERE cat.id = v_categoria_id
    AND cat.cadastro_id IS NULL;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_criar_categoria(text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_criar_categoria(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_criar_categoria(text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_criar_categoria(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_criar_categoria(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_criar_categoria(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_renomear_categoria(
  p_id uuid,
  p_nome text
) RETURNS TABLE (
  id uuid,
  nome text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_nome text := NULLIF(btrim(p_nome), '');
  v_rows integer := 0;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF v_nome IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: nome.'
      USING ERRCODE = '23502';
  END IF;

  UPDATE private.categorias cat
  SET nome = v_nome
  WHERE cat.id = p_id
    AND cat.cadastro_id IS NULL;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  RETURN QUERY
  SELECT cat.id, cat.nome, cat.created_at, cat.updated_at
  FROM private.categorias cat
  WHERE cat.id = p_id
    AND cat.cadastro_id IS NULL;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_renomear_categoria(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_excluir_categoria(
  p_id uuid
) RETURNS TABLE (
  id uuid,
  nome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_nome text;
  v_rows integer := 0;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  SELECT cat.nome INTO v_nome
  FROM private.categorias cat
  WHERE cat.id = p_id
    AND cat.cadastro_id IS NULL;

  IF v_nome IS NULL THEN
    RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  DELETE FROM private.categorias cat
  WHERE cat.id = p_id
    AND cat.cadastro_id IS NULL;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  RETURN QUERY SELECT p_id, v_nome;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_excluir_categoria(uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_categoria(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_categoria(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_categoria(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_categoria(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_excluir_categoria(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.rpc_admin_kb_preparar_upload(text, uuid, bigint);

CREATE OR REPLACE FUNCTION private.rpc_admin_kb_preparar_upload(
  p_escopo text,
  p_categoria_id uuid,
  p_tamanho_bytes bigint
) RETURNS TABLE (
  escopo text,
  categoria_id uuid,
  max_file_bytes bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_escopo text;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  v_escopo := private.normalizar_kb_admin_escopo(p_escopo);

  IF p_categoria_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: categoria_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_tamanho_bytes IS NULL OR p_tamanho_bytes <= 0 OR p_tamanho_bytes > 5242880 THEN
    RAISE EXCEPTION 'Parametro invalido: tamanho_bytes deve ser maior que zero e menor ou igual a 5MB.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM private.categorias cat
  WHERE cat.id = p_categoria_id
    AND cat.cadastro_id IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_categoria_id
      USING ERRCODE = '02000';
  END IF;

  escopo := v_escopo;
  categoria_id := p_categoria_id;
  max_file_bytes := 5242880;
  RETURN NEXT;
END;
$$;

ALTER FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint) FROM anon;
REVOKE ALL ON FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint) FROM authenticated;
REVOKE ALL ON FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint) FROM service_role;
GRANT EXECUTE ON FUNCTION private.rpc_admin_kb_preparar_upload(text, uuid, bigint) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_inserir_upload_documento(
  p_escopo text,
  p_categoria_id uuid,
  p_url_documento text,
  p_tamanho_bytes bigint,
  p_tipo_relatorio uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id uuid;
  v_auth_user_id uuid := public.request_jwt_sub();
  v_escopo text;
  v_categoria_id uuid;
BEGIN
  SELECT prep.escopo, prep.categoria_id
    INTO v_escopo, v_categoria_id
  FROM private.rpc_admin_kb_preparar_upload(
    p_escopo,
    p_categoria_id,
    p_tamanho_bytes
  ) prep;

  IF p_url_documento IS NULL OR btrim(p_url_documento) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: url_documento.'
      USING ERRCODE = '23502';
  END IF;

  INSERT INTO private.base_conhecimento (
    cadastro_id,
    documento,
    area_empresa,
    tipo_relatorio,
    url_documento,
    status_processamento,
    status_indexacao,
    tags,
    criado_por_auth_user_id
  ) VALUES (
    NULL,
    NULL,
    v_categoria_id,
    COALESCE(p_tipo_relatorio, extensions.uuid_generate_v4()),
    p_url_documento,
    'processando',
    'pendente',
    ARRAY[v_escopo]::text[],
    v_auth_user_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_inserir_upload_documento(text, uuid, text, bigint, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_inserir_documento_texto(
  p_escopo text,
  p_categoria_id uuid,
  p_documento text,
  p_tipo_relatorio uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id uuid;
  v_auth_user_id uuid := public.request_jwt_sub();
  v_escopo text := private.normalizar_kb_admin_escopo(p_escopo);
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_categoria_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: categoria_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_documento IS NULL OR btrim(p_documento) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: documento.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM 1
  FROM private.categorias cat
  WHERE cat.id = p_categoria_id
    AND cat.cadastro_id IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_categoria_id
      USING ERRCODE = '02000';
  END IF;

  INSERT INTO private.base_conhecimento (
    cadastro_id,
    documento,
    area_empresa,
    tipo_relatorio,
    url_documento,
    status_processamento,
    status_indexacao,
    tags,
    criado_por_auth_user_id
  ) VALUES (
    NULL,
    private.encrypt_value(p_documento),
    p_categoria_id,
    COALESCE(p_tipo_relatorio, extensions.uuid_generate_v4()),
    NULL,
    'processado',
    'pendente',
    ARRAY[v_escopo]::text[],
    v_auth_user_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_inserir_documento_texto(text, uuid, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_listar_documentos(
  p_escopo text DEFAULT 'publico'
) RETURNS TABLE (
  id uuid,
  tipo_relatorio uuid,
  hora_criacao timestamptz,
  documento text,
  tema text,
  categoria_id uuid,
  url_documento text,
  status_processamento text,
  status_indexacao text,
  indexado_em timestamptz,
  qtd_chunks integer,
  embedding_model text,
  erro_indexacao text,
  qtd_chunks_indexados integer,
  qtd_chunks_total_indexacao integer,
  percentual_indexacao integer,
  tags text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_escopo text := private.normalizar_kb_admin_escopo(p_escopo);
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH documentos AS MATERIALIZED (
    SELECT
      bc.id,
      bc.tipo_relatorio,
      bc.hora_criacao,
      private.decrypt_value(bc.documento) AS documento,
      cat.nome AS tema,
      cat.id AS categoria_id,
      bc.url_documento,
      bc.status_processamento,
      bc.status_indexacao,
      bc.indexado_em,
      bc.qtd_chunks,
      bc.embedding_model,
      bc.erro_indexacao,
      bc.tags
    FROM private.base_conhecimento bc
    LEFT JOIN private.categorias cat ON cat.id = bc.area_empresa
    WHERE bc.cadastro_id IS NULL
      AND bc.tags @> ARRAY[v_escopo]::text[]
  ),
  chunks_indexados AS MATERIALIZED (
    SELECT bcc.base_conhecimento_id, COUNT(*)::integer AS total_indexados
    FROM private.base_conhecimento_chunks bcc
    INNER JOIN documentos d ON d.id = bcc.base_conhecimento_id
    GROUP BY bcc.base_conhecimento_id
  ),
  chunks_pendentes AS MATERIALIZED (
    SELECT bcp.base_conhecimento_id, COUNT(*)::integer AS total_fila
    FROM private.base_conhecimento_chunks_pendentes bcp
    INNER JOIN documentos d ON d.id = bcp.base_conhecimento_id
    WHERE bcp.status = 'pendente'
    GROUP BY bcp.base_conhecimento_id
  ),
  progresso AS MATERIALIZED (
    SELECT
      d.id,
      COALESCE(ci.total_indexados, 0)::integer AS total_indexados,
      CASE
        WHEN d.status_indexacao = 'indexado' THEN NULLIF(
          GREATEST(
            COALESCE(d.qtd_chunks, 0),
            COALESCE(ci.total_indexados, 0)
          ),
          0
        )
        ELSE NULLIF(
          GREATEST(
            COALESCE(d.qtd_chunks, 0),
            COALESCE(ci.total_indexados, 0) + COALESCE(cp.total_fila, 0)
          ),
          0
        )
      END::integer AS total_indexacao
    FROM documentos d
    LEFT JOIN chunks_indexados ci ON ci.base_conhecimento_id = d.id
    LEFT JOIN chunks_pendentes cp ON cp.base_conhecimento_id = d.id
  )
  SELECT
    d.id,
    d.tipo_relatorio,
    d.hora_criacao,
    d.documento,
    d.tema,
    d.categoria_id,
    d.url_documento,
    d.status_processamento,
    d.status_indexacao,
    d.indexado_em,
    d.qtd_chunks,
    d.embedding_model,
    d.erro_indexacao,
    p.total_indexados,
    p.total_indexacao,
    CASE
      WHEN d.status_indexacao = 'indexado' THEN 100
      WHEN p.total_indexacao IS NULL OR p.total_indexacao <= 0 THEN NULL
      ELSE LEAST(
        99,
        GREATEST(
          0,
          FLOOR((p.total_indexados::numeric / p.total_indexacao::numeric) * 100)::integer
        )
      )
    END AS percentual_indexacao,
    d.tags
  FROM documentos d
  INNER JOIN progresso p ON p.id = d.id
  ORDER BY d.hora_criacao DESC, d.id DESC;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_listar_documentos(text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_documentos(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_documentos(text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_documentos(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_listar_documentos(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_listar_documentos(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_atualizar_documento(
  p_id uuid,
  p_escopo text DEFAULT NULL,
  p_categoria_id uuid DEFAULT NULL,
  p_documento text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_escopo text := CASE
    WHEN p_escopo IS NULL THEN NULL
    ELSE private.normalizar_kb_admin_escopo(p_escopo)
  END;
  v_rows integer := 0;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_categoria_id IS NOT NULL THEN
    PERFORM 1
    FROM private.categorias cat
    WHERE cat.id = p_categoria_id
      AND cat.cadastro_id IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Categoria publica/default nao encontrada: id %', p_categoria_id
        USING ERRCODE = '02000';
    END IF;
  END IF;

  UPDATE private.base_conhecimento bc
  SET
    area_empresa = COALESCE(p_categoria_id, bc.area_empresa),
    tags = CASE WHEN v_escopo IS NULL THEN bc.tags ELSE ARRAY[v_escopo]::text[] END,
    documento = CASE
      WHEN p_documento IS NULL THEN bc.documento
      WHEN btrim(p_documento) = '' THEN bc.documento
      ELSE private.encrypt_value(p_documento)
    END,
    status_processamento = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.status_processamento
      ELSE 'processado'
    END,
    status_indexacao = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.status_indexacao
      ELSE 'pendente'
    END,
    indexado_em = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.indexado_em
      ELSE NULL
    END,
    qtd_chunks = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.qtd_chunks
      ELSE NULL
    END,
    embedding_model = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.embedding_model
      ELSE NULL
    END,
    erro_indexacao = CASE
      WHEN p_documento IS NULL OR btrim(p_documento) = '' THEN bc.erro_indexacao
      ELSE NULL
    END
  WHERE bc.id = p_id
    AND bc.cadastro_id IS NULL
    AND private.base_conhecimento_is_system_scope(bc.id);

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento publico/default nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  IF p_documento IS NOT NULL AND btrim(p_documento) <> '' THEN
    DELETE FROM private.base_conhecimento_chunks bcc
    WHERE bcc.base_conhecimento_id = p_id;

    DELETE FROM private.base_conhecimento_chunks_pendentes bcp
    WHERE bcp.base_conhecimento_id = p_id;

    DELETE FROM private.base_conhecimento_documentos_indice bcdi
    WHERE bcdi.base_conhecimento_id = p_id;
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_atualizar_documento(uuid, text, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_excluir_documento(
  p_id uuid
) RETURNS TABLE (
  id uuid,
  url_documento text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_url_documento text;
  v_rows integer := 0;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  SELECT bc.url_documento
    INTO v_url_documento
  FROM private.base_conhecimento bc
  WHERE bc.id = p_id
    AND bc.cadastro_id IS NULL
    AND private.base_conhecimento_is_system_scope(bc.id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento publico/default nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  DELETE FROM private.base_conhecimento bc
  WHERE bc.id = p_id
    AND bc.cadastro_id IS NULL
    AND private.base_conhecimento_is_system_scope(bc.id);

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento publico/default nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  RETURN QUERY SELECT p_id, v_url_documento;
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_excluir_documento(uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_documento(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_documento(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_documento(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_excluir_documento(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_excluir_documento(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.dispatch_base_conhecimento_webhook(
  p_documento_id uuid,
  p_cadastro_id uuid,
  p_auth_user_id uuid,
  p_tipo_relatorio uuid,
  p_categoria_id uuid,
  p_categoria_nome text,
  p_url_documento text,
  p_status_processamento text,
  p_created_at timestamptz,
  p_origem text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
DECLARE
  v_webhook_url text;
  v_auth_header text;
  v_request_id bigint;
BEGIN
  PERFORM set_config('app.n8n_base_conhecimento_config_allowed', 'true', true);

  SELECT cfg.webhook_url, cfg.auth_header
    INTO v_webhook_url, v_auth_header
  FROM private.get_n8n_base_conhecimento_webhook_config() cfg;

  PERFORM set_config('app.n8n_base_conhecimento_config_allowed', '', true);

  v_request_id := private.http_post_seguro(
    p_url := v_webhook_url,
    p_body := jsonb_build_object(
      'documento_id', p_documento_id,
      'cadastro_id', p_cadastro_id,
      'auth_user_id', p_auth_user_id,
      'tipo_relatorio', p_tipo_relatorio,
      'categoria_id', p_categoria_id,
      'categoria', p_categoria_nome,
      'url_documento', p_url_documento,
      'status_processamento', p_status_processamento,
      'created_at', p_created_at,
      'origem', p_origem
    ),
    p_headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'auth', v_auth_header
    )
  );

  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'Falha ao enfileirar webhook n8n da base de conhecimento.'
      USING ERRCODE = '57014';
  END IF;
END;
$$;

ALTER FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) FROM anon;
REVOKE ALL ON FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) FROM authenticated;
REVOKE ALL ON FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) FROM service_role;
GRANT EXECUTE ON FUNCTION private.dispatch_base_conhecimento_webhook(
  uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz, text
) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.rpc_admin_kb_reprocessar_documento(
  p_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_auth_user_id uuid := public.request_jwt_sub();
  v_doc record;
  v_rows integer := 0;
BEGIN
  IF public.request_has_admin_profile('admin_docs') IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil admin_docs requerido'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  SELECT
    bc.id,
    bc.cadastro_id,
    bc.tipo_relatorio,
    bc.area_empresa,
    cat.nome AS categoria_nome,
    bc.url_documento,
    bc.hora_criacao
  INTO v_doc
  FROM private.base_conhecimento bc
  LEFT JOIN private.categorias cat ON cat.id = bc.area_empresa
  WHERE bc.id = p_id
    AND bc.cadastro_id IS NULL
    AND private.base_conhecimento_is_system_scope(bc.id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento publico/default nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  IF v_doc.url_documento IS NULL OR btrim(v_doc.url_documento) = '' THEN
    RAISE EXCEPTION 'Documento sem arquivo original para reprocessamento: id %', p_id
      USING ERRCODE = '22023';
  END IF;

  UPDATE private.base_conhecimento bc
  SET
    status_processamento = 'processando',
    documento = NULL,
    status_indexacao = 'pendente',
    indexado_em = NULL,
    qtd_chunks = NULL,
    embedding_model = NULL,
    erro_indexacao = NULL,
    criado_por_auth_user_id = v_auth_user_id
  WHERE bc.id = p_id
    AND bc.cadastro_id IS NULL
    AND private.base_conhecimento_is_system_scope(bc.id);

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Documento publico/default nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;

  DELETE FROM private.base_conhecimento_chunks bcc
  WHERE bcc.base_conhecimento_id = p_id;

  DELETE FROM private.base_conhecimento_chunks_pendentes bcp
  WHERE bcp.base_conhecimento_id = p_id;

  DELETE FROM private.base_conhecimento_documentos_indice bcdi
  WHERE bcdi.base_conhecimento_id = p_id;

  PERFORM private.dispatch_base_conhecimento_webhook(
    p_documento_id := p_id,
    p_cadastro_id := NULL,
    p_auth_user_id := v_auth_user_id,
    p_tipo_relatorio := v_doc.tipo_relatorio,
    p_categoria_id := v_doc.area_empresa,
    p_categoria_nome := v_doc.categoria_nome,
    p_url_documento := v_doc.url_documento,
    p_status_processamento := 'processando',
    p_created_at := v_doc.hora_criacao,
    p_origem := 'reprocessamento_admin'
  );
END;
$$;

ALTER FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kb_reprocessar_documento(uuid) TO authenticated;

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
