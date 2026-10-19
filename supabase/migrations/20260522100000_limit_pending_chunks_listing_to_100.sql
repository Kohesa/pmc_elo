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
  ORDER BY bcp.chunk_index
  LIMIT 100;
END;
$$;
