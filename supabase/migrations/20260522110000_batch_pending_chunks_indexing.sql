GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

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

  WITH input_chunks AS MATERIALIZED (
    SELECT
      item.chunk_pendente_id,
      item.embedding
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
      bcp.conteudo,
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
      AND EXISTS (
        SELECT 1
        FROM private.cadastro c
        WHERE c.id = bcp.cadastro_id
          AND c.auth_user_id = p_auth_user_id
      )
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
      vc.conteudo,
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
GRANT EXECUTE ON FUNCTION public.rpc_salvar_chunks_pendentes_indexados_lote_s2s(uuid, uuid, jsonb, text, text)
  TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;