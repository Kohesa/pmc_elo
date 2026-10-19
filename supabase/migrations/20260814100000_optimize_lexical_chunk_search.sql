-- Otimiza a busca lexical sobre chunks criptografados sem alterar o contrato da RPC.
--
-- Cada chunk recebe um indice invertido de trigramas protegidos por HMAC. A busca
-- usa o indice para selecionar candidatos e descriptografa somente os candidatos
-- e seus vizinhos. O LIKE final continua sendo a fonte de verdade, preservando a
-- semantica anterior inclusive para emails, documentos formatados e codigos.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.escape_like_text(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path TO pg_catalog
AS $$
  SELECT replace(
    replace(
      replace(COALESCE(p_value, ''), chr(92), chr(92) || chr(92)),
      '%',
      chr(92) || '%'
    ),
    '_',
    chr(92) || '_'
  );
$$;

ALTER FUNCTION private.escape_like_text(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.escape_like_text(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.escape_like_text(text) FROM anon;
REVOKE ALL ON FUNCTION private.escape_like_text(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.escape_like_text(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.escape_like_text(text) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.lexical_trigram_hashes(p_text text)
RETURNS bytea[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
DECLARE
  v_text text := lower(COALESCE(p_text, ''));
  v_key text;
  v_hashes bytea[];
BEGIN
  IF char_length(v_text) < 3 THEN
    RETURN ARRAY[]::bytea[];
  END IF;

  v_key := private.get_encryption_key();

  SELECT COALESCE(
    array_agg(
      extensions.hmac(
        'kb_lexical_trigram_v1:' || g.trigram,
        v_key,
        'sha256'
      )
      ORDER BY g.trigram
    ),
    ARRAY[]::bytea[]
  )
    INTO v_hashes
  FROM (
    SELECT DISTINCT substr(v_text, pos, 3) AS trigram
    FROM generate_series(1, char_length(v_text) - 2) AS pos
  ) g;

  RETURN v_hashes;
END;
$$;

ALTER FUNCTION private.lexical_trigram_hashes(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.lexical_trigram_hashes(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.lexical_trigram_hashes(text) FROM anon;
REVOKE ALL ON FUNCTION private.lexical_trigram_hashes(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.lexical_trigram_hashes(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.lexical_trigram_hashes(text) TO private_rpc_executor;

CREATE TABLE IF NOT EXISTS private.base_conhecimento_chunks_lexical (
  chunk_id uuid PRIMARY KEY,
  base_conhecimento_id uuid NOT NULL,
  trigram_hashes bytea[] NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT base_conhecimento_chunks_lexical_chunk_fkey
    FOREIGN KEY (chunk_id)
    REFERENCES private.base_conhecimento_chunks (id)
    ON DELETE CASCADE,
  CONSTRAINT base_conhecimento_chunks_lexical_documento_fkey
    FOREIGN KEY (base_conhecimento_id)
    REFERENCES private.base_conhecimento (id)
    ON DELETE CASCADE
);

ALTER TABLE private.base_conhecimento_chunks_lexical OWNER TO postgres;

REVOKE ALL ON TABLE private.base_conhecimento_chunks_lexical FROM PUBLIC;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_lexical FROM anon;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_lexical FROM authenticated;
REVOKE ALL ON TABLE private.base_conhecimento_chunks_lexical FROM service_role;
GRANT SELECT ON TABLE private.base_conhecimento_chunks_lexical TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.sync_base_conhecimento_chunk_lexical()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
BEGIN
  INSERT INTO private.base_conhecimento_chunks_lexical (
    chunk_id,
    base_conhecimento_id,
    trigram_hashes,
    updated_at
  ) VALUES (
    NEW.id,
    NEW.base_conhecimento_id,
    private.lexical_trigram_hashes(private.decrypt_value(NEW.conteudo)),
    now()
  )
  ON CONFLICT (chunk_id) DO UPDATE
  SET base_conhecimento_id = EXCLUDED.base_conhecimento_id,
      trigram_hashes = EXCLUDED.trigram_hashes,
      updated_at = EXCLUDED.updated_at;

  RETURN NEW;
END;
$$;

ALTER FUNCTION private.sync_base_conhecimento_chunk_lexical() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.sync_base_conhecimento_chunk_lexical() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.sync_base_conhecimento_chunk_lexical() FROM anon;
REVOKE ALL ON FUNCTION private.sync_base_conhecimento_chunk_lexical() FROM authenticated;
REVOKE ALL ON FUNCTION private.sync_base_conhecimento_chunk_lexical() FROM service_role;
REVOKE ALL ON FUNCTION private.sync_base_conhecimento_chunk_lexical() FROM private_rpc_executor;

DROP TRIGGER IF EXISTS trg_base_conhecimento_chunks_sync_lexical
  ON private.base_conhecimento_chunks;
CREATE TRIGGER trg_base_conhecimento_chunks_sync_lexical
AFTER INSERT OR UPDATE OF conteudo, base_conhecimento_id
ON private.base_conhecimento_chunks
FOR EACH ROW
EXECUTE FUNCTION private.sync_base_conhecimento_chunk_lexical();

-- Backfill unico. O timeout e desabilitado somente nesta sessao de migration.
SET statement_timeout TO 0;

INSERT INTO private.base_conhecimento_chunks_lexical (
  chunk_id,
  base_conhecimento_id,
  trigram_hashes,
  updated_at
)
SELECT
  bcc.id,
  bcc.base_conhecimento_id,
  private.lexical_trigram_hashes(private.decrypt_value(bcc.conteudo)),
  now()
FROM private.base_conhecimento_chunks bcc
ON CONFLICT (chunk_id) DO UPDATE
SET base_conhecimento_id = EXCLUDED.base_conhecimento_id,
    trigram_hashes = EXCLUDED.trigram_hashes,
    updated_at = EXCLUDED.updated_at;

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_chunks_lexical_trigrams
  ON private.base_conhecimento_chunks_lexical
  USING gin (trigram_hashes);

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_chunks_lexical_documento
  ON private.base_conhecimento_chunks_lexical (base_conhecimento_id, chunk_id);

ANALYZE private.base_conhecimento_chunks_lexical;

RESET statement_timeout;

CREATE OR REPLACE FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  p_wa_user_id text,
  p_termos text[],
  p_top_k integer DEFAULT 20,
  p_sessao_token text DEFAULT NULL,
  p_token_s2s text DEFAULT NULL,
  p_documento_ativo_id uuid DEFAULT NULL,
  p_usar_documento_ativo boolean DEFAULT false,
  p_chunks_por_documento integer DEFAULT 6,
  p_vizinhos integer DEFAULT 1,
  p_documentos_rejeitados uuid[] DEFAULT '{}'
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
  v_chunks_por_documento integer := COALESCE(p_chunks_por_documento, 6);
  v_vizinhos integer := COALESCE(p_vizinhos, 1);
  v_documentos_rejeitados uuid[] := COALESCE(p_documentos_rejeitados, '{}');
  v_termos text[];
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');

  SELECT array_agg(t.termo ORDER BY length(t.termo) DESC, t.termo)
    INTO v_termos
  FROM (
    SELECT dt.termo
    FROM (
      SELECT DISTINCT left(btrim(termo), 120) AS termo
      FROM unnest(COALESCE(p_termos, ARRAY[]::text[])) AS termo
      WHERE length(btrim(termo)) >= 3
    ) dt
    ORDER BY length(dt.termo) DESC, dt.termo
    LIMIT 10
  ) t;

  IF COALESCE(array_length(v_termos, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: termos.'
      USING ERRCODE = '23502';
  END IF;

  IF v_top_k < 1 OR v_top_k > 80 THEN
    RAISE EXCEPTION 'Parametro invalido: top_k deve estar entre 1 e 80.'
      USING ERRCODE = '22023';
  END IF;

  IF v_chunks_por_documento < 1 OR v_chunks_por_documento > 20 THEN
    RAISE EXCEPTION 'Parametro invalido: chunks_por_documento deve estar entre 1 e 20.'
      USING ERRCODE = '22023';
  END IF;

  IF v_vizinhos < 0 OR v_vizinhos > 3 THEN
    RAISE EXCEPTION 'Parametro invalido: vizinhos deve estar entre 0 e 3.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  PERFORM set_config('app.session_base_conhecimento_default_validated', 'true', true);
  PERFORM set_config('app.session_base_conhecimento_publica_validated', 'true', true);

  RETURN QUERY
  WITH query_terms AS MATERIALIZED (
    SELECT
      q.ordinality::integer AS termo_ordem,
      q.termo,
      private.lexical_trigram_hashes(q.termo) AS trigram_hashes
    FROM unnest(v_termos) WITH ORDINALITY AS q(termo, ordinality)
  ),
  allowed_docs AS MATERIALIZED (
    SELECT bc.id
    FROM private.base_conhecimento bc
    WHERE bc.cadastro_id IS NULL
      AND bc.tags @> ARRAY['publico']::text[]
      AND bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexado'

    UNION

    SELECT bc.id
    FROM private.base_conhecimento bc
    WHERE bc.cadastro_id IS NULL
      AND bc.tags @> ARRAY['default_elo']::text[]
      AND bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexado'
  ),
  matches_indexados AS MATERIALIZED (
    SELECT
      li.chunk_id,
      li.base_conhecimento_id,
      count(*)::integer AS termos_candidatos
    FROM query_terms qt
    INNER JOIN private.base_conhecimento_chunks_lexical li
      ON li.trigram_hashes @> qt.trigram_hashes
    INNER JOIN allowed_docs ad ON ad.id = li.base_conhecimento_id
    WHERE NOT (li.base_conhecimento_id = ANY(v_documentos_rejeitados))
    GROUP BY li.chunk_id, li.base_conhecimento_id
  ),
  chunks_candidatos AS MATERIALIZED (
    SELECT
      bcc.id AS chunk_id,
      bcc.base_conhecimento_id,
      private.decrypt_value(bcc.conteudo) AS conteudo,
      bcc.categoria_id,
      bcc.chunk_index,
      (
        p_usar_documento_ativo IS TRUE
        AND p_documento_ativo_id IS NOT NULL
        AND bcc.base_conhecimento_id = p_documento_ativo_id
      ) AS is_documento_ativo
    FROM matches_indexados mi
    INNER JOIN private.base_conhecimento_chunks bcc ON bcc.id = mi.chunk_id
  ),
  matches AS (
    SELECT
      cc.*,
      (
        SELECT count(*)::integer
        FROM unnest(v_termos) AS t(termo)
        WHERE lower(cc.conteudo) LIKE
          '%' || private.escape_like_text(lower(t.termo)) || '%'
          ESCAPE chr(92)
      ) AS termos_encontrados
    FROM chunks_candidatos cc
  ),
  matches_rankeados AS (
    SELECT
      m.*,
      (
        m.termos_encontrados::double precision
        + CASE WHEN m.is_documento_ativo THEN 0.25 ELSE 0 END
      ) AS score_chunk,
      (
        sum(m.termos_encontrados) OVER (
          PARTITION BY m.base_conhecimento_id
        )::double precision
        + CASE WHEN m.is_documento_ativo THEN 0.25 ELSE 0 END
      ) AS score_documento,
      row_number() OVER (
        PARTITION BY m.base_conhecimento_id
        ORDER BY
          m.termos_encontrados DESC,
          CASE WHEN m.is_documento_ativo THEN 0 ELSE 1 END,
          m.chunk_index
      ) AS rn_documento
    FROM matches m
    WHERE m.termos_encontrados > 0
  ),
  matches_base AS (
    SELECT *
    FROM matches_rankeados mr
    WHERE mr.rn_documento <= v_chunks_por_documento
    ORDER BY
      CASE WHEN mr.is_documento_ativo THEN 0 ELSE 1 END,
      mr.score_documento DESC,
      mr.score_chunk DESC,
      mr.base_conhecimento_id,
      mr.chunk_index
    LIMIT v_top_k
  ),
  chunks_expandidos AS (
    SELECT
      bcc.id AS chunk_id,
      bcc.base_conhecimento_id,
      CASE
        WHEN bcc.id = mb.chunk_id THEN mb.conteudo
        ELSE private.decrypt_value(bcc.conteudo)
      END AS conteudo,
      CASE
        WHEN bcc.id = mb.chunk_id THEN mb.score_chunk
        ELSE greatest(mb.score_chunk - 0.0001, 0)
      END AS score_chunk,
      mb.score_documento,
      bcc.categoria_id,
      bcc.chunk_index,
      CASE
        WHEN bcc.id = mb.chunk_id AND mb.is_documento_ativo THEN 'lexical_documento_ativo'
        WHEN bcc.id = mb.chunk_id THEN 'lexical'
        WHEN mb.is_documento_ativo THEN 'lexical_documento_ativo_vizinho'
        ELSE 'lexical_vizinho'
      END AS origem
    FROM matches_base mb
    INNER JOIN private.base_conhecimento_chunks bcc
      ON bcc.base_conhecimento_id = mb.base_conhecimento_id
     AND bcc.chunk_index BETWEEN mb.chunk_index - v_vizinhos AND mb.chunk_index + v_vizinhos
  ),
  deduplicado AS (
    SELECT DISTINCT ON (ce.chunk_id)
      ce.chunk_id,
      ce.base_conhecimento_id,
      ce.conteudo,
      ce.score_chunk,
      ce.score_documento,
      ce.categoria_id,
      ce.chunk_index,
      ce.origem
    FROM chunks_expandidos ce
    ORDER BY ce.chunk_id, ce.score_chunk DESC, ce.score_documento DESC
  )
  SELECT
    d.chunk_id,
    d.base_conhecimento_id,
    CASE
      WHEN bcdi.titulo_detectado_enc IS NULL THEN NULL
      ELSE private.decrypt_value(bcdi.titulo_detectado_enc)
    END AS documento_titulo,
    d.conteudo,
    d.score_chunk AS score,
    d.score_documento,
    d.categoria_id,
    d.chunk_index,
    d.origem
  FROM deduplicado d
  LEFT JOIN private.base_conhecimento_documentos_indice bcdi
    ON bcdi.base_conhecimento_id = d.base_conhecimento_id
  ORDER BY d.score_documento DESC, d.score_chunk DESC, d.base_conhecimento_id, d.chunk_index
  LIMIT v_top_k;
END;
$$;

ALTER FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_buscar_chunks_base_conhecimento_texto_s2s(
  text, text[], integer, text, text, uuid, boolean, integer, integer, uuid[]
) TO service_role;

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
