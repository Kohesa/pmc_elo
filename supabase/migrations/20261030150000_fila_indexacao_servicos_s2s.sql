-- Fila reutilizavel para indexacao dos servicos publicados da Elo.
-- O n8n reserva os itens por RPC, envia apenas descricao_busca ao provedor de
-- embeddings e persiste o resultado em lote por uma segunda RPC S2S.

-- Permissao temporaria exigida pelo PostgreSQL para transferir a propriedade
-- das RPCs ao papel executor. Ela e revogada no final da migration.
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

ALTER TABLE private.cadastro_servicos
  ADD COLUMN IF NOT EXISTS tentativas_indexacao integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ultima_tentativa_indexacao timestamptz;

ALTER TABLE private.cadastro_servicos
  DROP CONSTRAINT IF EXISTS cadastro_servicos_tentativas_indexacao_check,
  ADD CONSTRAINT cadastro_servicos_tentativas_indexacao_check
    CHECK (tentativas_indexacao >= 0);

CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_fila_indexacao
  ON private.cadastro_servicos (
    status_indexacao,
    ultima_tentativa_indexacao,
    updated_at,
    id
  )
  WHERE ativo AND publicado;

DROP FUNCTION IF EXISTS public.rpc_reservar_servicos_indexacao_pendentes_s2s(integer, text);
DROP FUNCTION IF EXISTS public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer);

CREATE FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(
  p_token_s2s text,
  p_limite integer DEFAULT 100
)
RETURNS TABLE (
  servico_id uuid,
  descricao_busca text,
  tentativa integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, extensions
AS $$
DECLARE
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 100), 1), 100);
BEGIN
  PERFORM private.validar_token_s2s(
    p_token_s2s,
    'processar_base_conhecimento'
  );

  PERFORM set_config('app.session_importacao_empresarios', 'true', true);

  RETURN QUERY
  WITH candidatos AS (
    SELECT cs.id
    FROM private.cadastro_servicos cs
    JOIN private.cadastro c ON c.id = cs.cadastro_id
    WHERE cs.ativo
      AND cs.publicado
      AND c.status = 'aprovado'
      AND c.perfil_ativo
      AND c.cadastro_concluido_em IS NOT NULL
      AND c.autoriza_publicacao
      AND NULLIF(BTRIM(cs.descricao_busca), '') IS NOT NULL
      AND cs.tentativas_indexacao < 5
      AND (
        cs.status_indexacao = 'pendente'
        OR cs.status_indexacao = 'erro'
        OR (
          cs.status_indexacao = 'indexando'
          AND COALESCE(cs.ultima_tentativa_indexacao, cs.updated_at)
            < clock_timestamp() - interval '30 minutes'
        )
      )
    ORDER BY
      CASE cs.status_indexacao
        WHEN 'pendente' THEN 0
        WHEN 'erro' THEN 1
        ELSE 2
      END,
      COALESCE(cs.ultima_tentativa_indexacao, cs.created_at),
      cs.created_at,
      cs.id
    FOR UPDATE OF cs SKIP LOCKED
    LIMIT v_limite
  ), reservados AS (
    UPDATE private.cadastro_servicos cs
       SET status_indexacao = 'indexando',
           tentativas_indexacao = cs.tentativas_indexacao + 1,
           ultima_tentativa_indexacao = clock_timestamp(),
           erro_indexacao = NULL,
           updated_at = clock_timestamp()
      FROM candidatos f
     WHERE cs.id = f.id
    RETURNING
      cs.id,
      cs.descricao_busca,
      cs.tentativas_indexacao
  )
  SELECT
    r.id,
    r.descricao_busca,
    r.tentativas_indexacao
  FROM reservados r
  ORDER BY r.id;
END;
$$;

ALTER FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer)
  TO service_role;

COMMENT ON FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer)
  IS 'Reserva atomicamente servicos publicados pendentes de embedding. Requer S2S no escopo processar_base_conhecimento.';

DROP FUNCTION IF EXISTS public.rpc_salvar_indices_servicos_lote_s2s(text, jsonb, text);

CREATE FUNCTION public.rpc_salvar_indices_servicos_lote_s2s(
  p_token_s2s text,
  p_itens jsonb,
  p_embedding_model text DEFAULT 'openai/text-embedding-3-small'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, extensions
AS $$
DECLARE
  v_quantidade_entrada integer;
  v_quantidade_atualizada integer;
BEGIN
  PERFORM private.validar_token_s2s(
    p_token_s2s,
    'processar_base_conhecimento'
  );

  IF jsonb_typeof(p_itens) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_itens deve ser um array JSON.' USING ERRCODE = '22023';
  END IF;

  v_quantidade_entrada := jsonb_array_length(p_itens);
  IF v_quantidade_entrada < 1 OR v_quantidade_entrada > 100 THEN
    RAISE EXCEPTION 'O lote deve conter entre 1 e 100 servicos.' USING ERRCODE = '22023';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_embedding_model, '')), '') IS NULL THEN
    RAISE EXCEPTION 'p_embedding_model e obrigatorio.' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.session_importacao_empresarios', 'true', true);

  WITH itens AS (
    SELECT
      (item ->> 'servico_id')::uuid AS servico_id,
      NULLIF(BTRIM(item ->> 'descricao_busca'), '') AS descricao_busca,
      (item -> 'embedding')::text::extensions.vector(384) AS embedding
    FROM jsonb_array_elements(p_itens) item
    WHERE item ? 'servico_id'
      AND jsonb_typeof(item -> 'embedding') = 'array'
  ), atualizados AS (
    UPDATE private.cadastro_servicos cs
       SET descricao_busca = COALESCE(i.descricao_busca, cs.descricao_busca),
           documento_fts = to_tsvector(
             'portuguese',
             COALESCE(i.descricao_busca, cs.descricao_busca, '')
           ),
           embedding = i.embedding,
           status_indexacao = 'indexado',
           embedding_model = BTRIM(p_embedding_model),
           indexed_at = clock_timestamp(),
           erro_indexacao = NULL,
           updated_at = clock_timestamp()
      FROM itens i
     WHERE cs.id = i.servico_id
       AND cs.status_indexacao = 'indexando'
    RETURNING cs.id
  )
  SELECT COUNT(*)::integer
    INTO v_quantidade_atualizada
  FROM atualizados;

  IF v_quantidade_atualizada <> v_quantidade_entrada THEN
    RAISE EXCEPTION
      'Lote inconsistente: % item(ns) recebido(s) e % atualizado(s).',
      v_quantidade_entrada,
      v_quantidade_atualizada
      USING ERRCODE = '22023';
  END IF;

  RETURN v_quantidade_atualizada;
END;
$$;

ALTER FUNCTION public.rpc_salvar_indices_servicos_lote_s2s(text, jsonb, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_salvar_indices_servicos_lote_s2s(text, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_indices_servicos_lote_s2s(text, jsonb, text)
  TO service_role;

COMMENT ON FUNCTION public.rpc_salvar_indices_servicos_lote_s2s(text, jsonb, text)
  IS 'Persiste embeddings de servicos reservados em lote. Requer S2S no escopo processar_base_conhecimento.';

COMMENT ON COLUMN private.cadastro_servicos.tentativas_indexacao
  IS 'Quantidade de reservas para processamento do embedding, limitada a cinco pela fila automatica.';
COMMENT ON COLUMN private.cadastro_servicos.ultima_tentativa_indexacao
  IS 'Momento da ultima reserva; permite recuperar itens travados em indexando.';

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
