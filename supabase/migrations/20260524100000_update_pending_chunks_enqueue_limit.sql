-- Atualiza limite da fila de chunks pendentes.
-- Agora a RPC aceita qualquer lote nao vazio e bloqueia documentos acima de 5000 chunks.

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

  IF v_qtd_chunks > 5000 THEN
    RAISE EXCEPTION 'Limite maximo de chunks excedido: recebido %, maximo permitido 5000.', v_qtd_chunks
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
