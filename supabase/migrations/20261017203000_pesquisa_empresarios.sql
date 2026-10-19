-- Primeira entrega da Elo: diretorio pesquisavel de empresarios e servicos.
--
-- Mantem cadastro como fonte oficial e usa cadastro_servicos como catalogo
-- pesquisavel. A base de conhecimento permanece institucional. Todas as entradas
-- externas continuam passando por RPC S2S e por uma sessao Chatwoot valida.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;
GRANT CREATE ON SCHEMA private TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- Perfil publico do cadastro e servicos estruturados.
-- ---------------------------------------------------------------------------

ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS nome_preferido text,
  ADD COLUMN IF NOT EXISTS descricao_negocio text,
  ADD COLUMN IF NOT EXISTS setor text,
  ADD COLUMN IF NOT EXISTS cidade text,
  ADD COLUMN IF NOT EXISTS estado text,
  ADD COLUMN IF NOT EXISTS site text,
  ADD COLUMN IF NOT EXISTS perfil_ativo boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS cadastro_concluido_em timestamptz,
  ADD COLUMN IF NOT EXISTS autoriza_publicacao boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS autoriza_publicacao_em timestamptz,
  ADD COLUMN IF NOT EXISTS publicacao_termo_versao text,
  ADD COLUMN IF NOT EXISTS publicar_telefone boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS publicar_email boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS publicar_instagram boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS publicar_linkedin boolean NOT NULL DEFAULT false;

ALTER TABLE private.cadastro
  DROP CONSTRAINT IF EXISTS cadastro_autoriza_publicacao_em_check,
  ADD CONSTRAINT cadastro_autoriza_publicacao_em_check
    CHECK (autoriza_publicacao IS FALSE OR autoriza_publicacao_em IS NOT NULL),
  DROP CONSTRAINT IF EXISTS cadastro_estado_check,
  ADD CONSTRAINT cadastro_estado_check
    CHECK (estado IS NULL OR btrim(estado) ~ '^[A-Za-z]{2}$');

CREATE TABLE IF NOT EXISTS private.cadastro_servicos (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  cadastro_id uuid NOT NULL REFERENCES private.cadastro(id) ON DELETE CASCADE,
  nome text NOT NULL,
  descricao text NOT NULL,
  problemas_resolvidos text,
  especialidades text[] NOT NULL DEFAULT '{}'::text[],
  categoria_nome text NOT NULL,
  categoria_aliases text[] NOT NULL DEFAULT '{}'::text[],
  cidade text,
  estado text,
  descricao_busca text,
  documento_fts tsvector,
  embedding extensions.vector(384),
  status_indexacao text NOT NULL DEFAULT 'pendente',
  embedding_model text,
  indexed_at timestamptz,
  erro_indexacao text,
  ativo boolean NOT NULL DEFAULT true,
  publicado boolean NOT NULL DEFAULT false,
  publicado_em timestamptz,
  origem_carga text NOT NULL DEFAULT 'controlada',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cadastro_servicos_nome_check CHECK (btrim(nome) <> ''),
  CONSTRAINT cadastro_servicos_descricao_check CHECK (btrim(descricao) <> ''),
  CONSTRAINT cadastro_servicos_categoria_check CHECK (btrim(categoria_nome) <> ''),
  CONSTRAINT cadastro_servicos_estado_check CHECK (estado IS NULL OR btrim(estado) ~ '^[A-Za-z]{2}$'),
  CONSTRAINT cadastro_servicos_publicado_em_check CHECK (publicado IS FALSE OR publicado_em IS NOT NULL),
  CONSTRAINT cadastro_servicos_especialidades_check CHECK (array_position(especialidades, NULL) IS NULL),
  CONSTRAINT cadastro_servicos_aliases_check CHECK (array_position(categoria_aliases, NULL) IS NULL),
  CONSTRAINT cadastro_servicos_status_indexacao_check
    CHECK (status_indexacao IN ('pendente', 'indexando', 'indexado', 'erro'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cadastro_servicos_nome_normalizado
  ON private.cadastro_servicos (cadastro_id, lower(btrim(nome)));
CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_publicados
  ON private.cadastro_servicos (publicado, ativo, status_indexacao, cadastro_id, created_at, id);
CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_categoria
  ON private.cadastro_servicos (lower(btrim(categoria_nome)));
CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_documento_fts
  ON private.cadastro_servicos USING gin (documento_fts);
CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_embedding
  ON private.cadastro_servicos USING hnsw (embedding extensions.vector_cosine_ops)
  WHERE embedding IS NOT NULL;

CREATE OR REPLACE FUNCTION private.touch_cadastro_servicos_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

ALTER FUNCTION private.touch_cadastro_servicos_updated_at() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.touch_cadastro_servicos_updated_at() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_cadastro_servicos_updated_at ON private.cadastro_servicos;
CREATE TRIGGER trg_cadastro_servicos_updated_at
BEFORE UPDATE ON private.cadastro_servicos
FOR EACH ROW EXECUTE FUNCTION private.touch_cadastro_servicos_updated_at();

ALTER TABLE private.cadastro_servicos ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON private.cadastro_servicos TO private_rpc_executor;

-- O catálogo de serviços possui o próprio índice textual e vetorial. A base de
-- conhecimento permanece dedicada aos documentos institucionais da Elo.
CREATE OR REPLACE FUNCTION private.refresh_cadastro_servicos_documento_fts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'private'
AS $$
BEGIN
  NEW.documento_fts := to_tsvector(
    'portuguese',
    concat_ws(' ',
      NEW.nome,
      NEW.categoria_nome,
      array_to_string(NEW.categoria_aliases, ' '),
      NEW.descricao,
      NEW.descricao_busca,
      NEW.problemas_resolvidos,
      array_to_string(NEW.especialidades, ' ')
    )
  );
  RETURN NEW;
END;
$$;

ALTER FUNCTION private.refresh_cadastro_servicos_documento_fts()
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.refresh_cadastro_servicos_documento_fts()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_cadastro_servicos_documento_fts ON private.cadastro_servicos;
CREATE TRIGGER trg_cadastro_servicos_documento_fts
BEFORE INSERT OR UPDATE OF nome, categoria_nome, categoria_aliases, descricao,
  descricao_busca, problemas_resolvidos, especialidades
ON private.cadastro_servicos
FOR EACH ROW EXECUTE FUNCTION private.refresh_cadastro_servicos_documento_fts();

-- ---------------------------------------------------------------------------
-- Flags internas e politicas RLS. As flags somente sao ativadas dentro de RPCs
-- SECURITY DEFINER depois da validacao S2S/sessao.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS cadastro_importacao_empresarios ON private.cadastro;
CREATE POLICY cadastro_importacao_empresarios ON private.cadastro
FOR ALL TO private_rpc_executor
USING (current_setting('app.session_importacao_empresarios', true) = 'true')
WITH CHECK (current_setting('app.session_importacao_empresarios', true) = 'true');

DROP POLICY IF EXISTS cadastro_pesquisa_empresarios ON private.cadastro;
CREATE POLICY cadastro_pesquisa_empresarios ON private.cadastro
FOR SELECT TO private_rpc_executor
USING (
  current_setting('app.session_pesquisa_empresarios', true) = 'true'
  AND status = 'aprovado'
  AND perfil_ativo
  AND cadastro_concluido_em IS NOT NULL
  AND autoriza_publicacao
);

DROP POLICY IF EXISTS cadastro_servicos_operacao_controlada ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_operacao_controlada ON private.cadastro_servicos
FOR ALL TO private_rpc_executor
USING (
  current_setting('app.session_importacao_empresarios', true) = 'true'
  OR (
    current_setting('app.session_s2s_validated', true) = 'true'
    AND cadastro_id = private.get_session_auth_user_id()
  )
)
WITH CHECK (
  current_setting('app.session_importacao_empresarios', true) = 'true'
  OR (
    current_setting('app.session_s2s_validated', true) = 'true'
    AND cadastro_id = private.get_session_auth_user_id()
  )
);

DROP POLICY IF EXISTS cadastro_servicos_pesquisa ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_pesquisa ON private.cadastro_servicos
FOR SELECT TO private_rpc_executor
USING (
  current_setting('app.session_pesquisa_empresarios', true) = 'true'
  AND ativo
  AND publicado
);

-- As politicas e helpers da base institucional permanecem definidos pelas migrations anteriores.

-- ---------------------------------------------------------------------------
-- Normalizacao lexical compartilhada pela carga e pela pesquisa.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.elo_normalizar_texto(p_valor text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path TO pg_catalog
AS $$
  SELECT btrim(regexp_replace(
    translate(
      lower(COALESCE(p_valor, '')),
      'áàâãäéèêëíìîïóòôõöúùûüçñ',
      'aaaaaeeeeiiiiooooouuuucn'
    ),
    '[^a-z0-9]+',
    ' ',
    'g'
  ));
$$;

ALTER FUNCTION private.elo_normalizar_texto(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.elo_normalizar_texto(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.elo_normalizar_texto(text) TO private_rpc_executor;



-- ---------------------------------------------------------------------------
-- Carga controlada. Esta e a entrada da primeira entrega; o cadastro
-- conversacional sera implementado depois.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_importar_servico_empresario_s2s(
  text, text, text, text, text, text, boolean, uuid, text, text, text, text,
  text[], text[], text, text, text, text, text, text, text, boolean, boolean,
  boolean, boolean, timestamptz, text
);

CREATE FUNCTION public.rpc_importar_servico_empresario_s2s(
  p_token_s2s text,
  p_nome text,
  p_empresa text,
  p_categoria text,
  p_servico text,
  p_descricao text,
  p_autoriza_publicacao boolean,
  p_cadastro_id uuid DEFAULT NULL,
  p_nome_preferido text DEFAULT NULL,
  p_cargo text DEFAULT NULL,
  p_setor text DEFAULT NULL,
  p_problemas_resolvidos text DEFAULT NULL,
  p_especialidades text[] DEFAULT '{}'::text[],
  p_categoria_aliases text[] DEFAULT '{}'::text[],
  p_cidade text DEFAULT NULL,
  p_estado text DEFAULT NULL,
  p_site text DEFAULT NULL,
  p_telefone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL,
  p_publicar_telefone boolean DEFAULT false,
  p_publicar_email boolean DEFAULT false,
  p_publicar_instagram boolean DEFAULT false,
  p_publicar_linkedin boolean DEFAULT false,
  p_created_at timestamptz DEFAULT now(),
  p_versao_termo text DEFAULT 'carga-controlada-v1'
) RETURNS TABLE (
  cadastro_id uuid,
  servico_id uuid,
  status_indexacao text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_cadastro_id uuid;
  v_servico_id uuid;
  v_estado text := upper(NULLIF(btrim(p_estado), ''));
  v_categoria_nome text := COALESCE(NULLIF(btrim(p_categoria), ''), btrim(p_servico));
  v_agora timestamptz := now();
  v_descricao_busca text;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'processar_base_conhecimento');
  PERFORM set_config('app.session_importacao_empresarios', 'true', true);

  IF p_autoriza_publicacao IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'A publicacao exige autorizacao explicita registrada na origem da carga.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(btrim(p_nome), '') IS NULL
     OR NULLIF(btrim(p_empresa), '') IS NULL
     OR NULLIF(btrim(p_servico), '') IS NULL
     OR NULLIF(btrim(p_descricao), '') IS NULL THEN
    RAISE EXCEPTION 'Nome, empresa, servico e descricao sao obrigatorios.' USING ERRCODE = '23502';
  END IF;
  IF v_estado IS NOT NULL AND v_estado !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'Estado deve conter a sigla de duas letras.' USING ERRCODE = '22023';
  END IF;

  IF p_cadastro_id IS NULL THEN
    INSERT INTO private.cadastro (
      nome, nome_preferido, tipo, empresa, cargo, descricao_negocio, setor,
      cidade, estado, site, telefone_enc, telefone_hash, email_enc,
      instagram_enc, linkedin_enc, status, perfil_ativo, cadastro_concluido_em,
      autoriza_publicacao, autoriza_publicacao_em, publicacao_termo_versao,
      publicar_telefone, publicar_email, publicar_instagram, publicar_linkedin,
      created_at, updated_at
    ) VALUES (
      btrim(p_nome), NULLIF(btrim(p_nome_preferido), ''), 'Pessoa', btrim(p_empresa),
      NULLIF(btrim(p_cargo), ''), btrim(p_descricao), NULLIF(btrim(p_setor), ''),
      NULLIF(btrim(p_cidade), ''), v_estado, NULLIF(btrim(p_site), ''),
      CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_telefone)) END,
      CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN NULL ELSE private.hash_value(btrim(p_telefone)) END,
      CASE WHEN NULLIF(btrim(p_email), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_email)) END,
      CASE WHEN NULLIF(btrim(p_instagram), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_instagram)) END,
      CASE WHEN NULLIF(btrim(p_linkedin), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_linkedin)) END,
      'aprovado', true, v_agora, true, v_agora,
      COALESCE(NULLIF(btrim(p_versao_termo), ''), 'carga-controlada-v1'),
      COALESCE(p_publicar_telefone, false), COALESCE(p_publicar_email, false),
      COALESCE(p_publicar_instagram, false), COALESCE(p_publicar_linkedin, false),
      COALESCE(p_created_at, v_agora), v_agora
    ) RETURNING id INTO v_cadastro_id;
  ELSE
    UPDATE private.cadastro c
    SET nome = btrim(p_nome),
        nome_preferido = NULLIF(btrim(p_nome_preferido), ''),
        empresa = btrim(p_empresa),
        cargo = NULLIF(btrim(p_cargo), ''),
        descricao_negocio = btrim(p_descricao),
        setor = NULLIF(btrim(p_setor), ''),
        cidade = NULLIF(btrim(p_cidade), ''),
        estado = v_estado,
        site = NULLIF(btrim(p_site), ''),
        telefone_enc = CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN c.telefone_enc ELSE private.encrypt_value(btrim(p_telefone)) END,
        telefone_hash = CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN c.telefone_hash ELSE private.hash_value(btrim(p_telefone)) END,
        email_enc = CASE WHEN NULLIF(btrim(p_email), '') IS NULL THEN c.email_enc ELSE private.encrypt_value(btrim(p_email)) END,
        instagram_enc = CASE WHEN NULLIF(btrim(p_instagram), '') IS NULL THEN c.instagram_enc ELSE private.encrypt_value(btrim(p_instagram)) END,
        linkedin_enc = CASE WHEN NULLIF(btrim(p_linkedin), '') IS NULL THEN c.linkedin_enc ELSE private.encrypt_value(btrim(p_linkedin)) END,
        status = 'aprovado', perfil_ativo = true,
        cadastro_concluido_em = COALESCE(c.cadastro_concluido_em, v_agora),
        autoriza_publicacao = true,
        autoriza_publicacao_em = COALESCE(c.autoriza_publicacao_em, v_agora),
        publicacao_termo_versao = COALESCE(NULLIF(btrim(p_versao_termo), ''), c.publicacao_termo_versao, 'carga-controlada-v1'),
        publicar_telefone = COALESCE(p_publicar_telefone, false),
        publicar_email = COALESCE(p_publicar_email, false),
        publicar_instagram = COALESCE(p_publicar_instagram, false),
        publicar_linkedin = COALESCE(p_publicar_linkedin, false),
        updated_at = v_agora
    WHERE c.id = p_cadastro_id
    RETURNING c.id INTO v_cadastro_id;

    IF v_cadastro_id IS NULL THEN
      RAISE EXCEPTION 'Cadastro informado nao encontrado.' USING ERRCODE = '02000';
    END IF;
  END IF;

  v_descricao_busca := concat_ws(E'\n',
    'Empresa: ' || btrim(p_empresa),
    'Servico: ' || btrim(p_servico),
    'Categoria informada: ' || v_categoria_nome,
    'Descricao: ' || btrim(p_descricao),
    CASE WHEN NULLIF(btrim(p_problemas_resolvidos), '') IS NOT NULL
      THEN 'Problemas atendidos: ' || btrim(p_problemas_resolvidos) END,
    CASE WHEN cardinality(COALESCE(p_especialidades, '{}'::text[])) > 0
      THEN 'Especialidades: ' || array_to_string(p_especialidades, ', ') END,
    CASE WHEN cardinality(COALESCE(p_categoria_aliases, '{}'::text[])) > 0
      THEN 'Termos informados: ' || array_to_string(p_categoria_aliases, ', ') END
  );

  SELECT cs.id INTO v_servico_id
  FROM private.cadastro_servicos cs
  WHERE cs.cadastro_id = v_cadastro_id
    AND lower(btrim(cs.nome)) = lower(btrim(p_servico))
  LIMIT 1;

  IF v_servico_id IS NULL THEN
    INSERT INTO private.cadastro_servicos (
      cadastro_id, nome, descricao, problemas_resolvidos, especialidades,
      categoria_nome, categoria_aliases, cidade, estado, descricao_busca,
      status_indexacao, embedding, embedding_model, indexed_at, erro_indexacao,
      ativo, publicado, publicado_em, origem_carga
    ) VALUES (
      v_cadastro_id, btrim(p_servico), btrim(p_descricao), NULLIF(btrim(p_problemas_resolvidos), ''),
      COALESCE(p_especialidades, '{}'::text[]), v_categoria_nome, COALESCE(p_categoria_aliases, '{}'::text[]),
      NULLIF(btrim(p_cidade), ''), v_estado, v_descricao_busca,
      'pendente', NULL, NULL, NULL, NULL, true, true, v_agora, 'controlada'
    ) RETURNING id INTO v_servico_id;
  ELSE
    UPDATE private.cadastro_servicos cs
    SET descricao = btrim(p_descricao),
        problemas_resolvidos = NULLIF(btrim(p_problemas_resolvidos), ''),
        especialidades = COALESCE(p_especialidades, '{}'::text[]),
        categoria_nome = v_categoria_nome,
        categoria_aliases = COALESCE(p_categoria_aliases, '{}'::text[]),
        cidade = NULLIF(btrim(p_cidade), ''),
        estado = v_estado,
        descricao_busca = v_descricao_busca,
        embedding = NULL,
        embedding_model = NULL,
        indexed_at = NULL,
        erro_indexacao = NULL,
        status_indexacao = 'pendente',
        ativo = true,
        publicado = true,
        publicado_em = COALESCE(cs.publicado_em, v_agora)
    WHERE cs.id = v_servico_id;
  END IF;

  RETURN QUERY SELECT v_cadastro_id, v_servico_id, 'pendente'::text;
END;
$$;

ALTER FUNCTION public.rpc_importar_servico_empresario_s2s(
  text, text, text, text, text, text, boolean, uuid, text, text, text, text,
  text[], text[], text, text, text, text, text, text, text, boolean, boolean,
  boolean, boolean, timestamptz, text
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_importar_servico_empresario_s2s(
  text, text, text, text, text, text, boolean, uuid, text, text, text, text,
  text[], text[], text, text, text, text, text, text, text, boolean, boolean,
  boolean, boolean, timestamptz, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_importar_servico_empresario_s2s(
  text, text, text, text, text, text, boolean, uuid, text, text, text, text,
  text[], text[], text, text, text, text, text, text, text, boolean, boolean,
  boolean, boolean, timestamptz, text
) TO service_role;

DROP FUNCTION IF EXISTS public.rpc_atualizar_indice_servico_s2s(
  text, uuid, text, extensions.vector, text
);

CREATE FUNCTION public.rpc_atualizar_indice_servico_s2s(
  p_token_s2s text,
  p_servico_id uuid,
  p_descricao_busca text,
  p_embedding extensions.vector(384),
  p_embedding_model text DEFAULT 'openai/text-embedding-3-small'
) RETURNS TABLE (
  servico_id uuid,
  status_indexacao text,
  indexed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'processar_base_conhecimento');
  PERFORM set_config('app.session_importacao_empresarios', 'true', true);

  IF NULLIF(btrim(p_descricao_busca), '') IS NULL OR p_embedding IS NULL THEN
    RAISE EXCEPTION 'Descricao de busca e embedding sao obrigatorios.' USING ERRCODE = '23502';
  END IF;

  RETURN QUERY
  UPDATE private.cadastro_servicos cs
  SET descricao_busca = btrim(p_descricao_busca),
      embedding = p_embedding,
      embedding_model = COALESCE(NULLIF(btrim(p_embedding_model), ''), 'openai/text-embedding-3-small'),
      status_indexacao = 'indexado',
      indexed_at = now(),
      erro_indexacao = NULL
  WHERE cs.id = p_servico_id
  RETURNING cs.id, cs.status_indexacao, cs.indexed_at;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Servico informado nao encontrado.' USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_atualizar_indice_servico_s2s(
  text, uuid, text, extensions.vector, text
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_atualizar_indice_servico_s2s(
  text, uuid, text, extensions.vector, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_indice_servico_s2s(
  text, uuid, text, extensions.vector, text
) TO service_role;

-- ---------------------------------------------------------------------------
-- Recuperacao hibrida do catalogo. A RPC encontra candidatos; a qualificacao
-- final e o corte de 50% pertencem ao reranker no n8n.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_buscar_empresarios_s2s(
  text, text, extensions.vector, text, text, text, double precision, integer, text, text
);
DROP FUNCTION IF EXISTS public.rpc_buscar_candidatos_servicos_s2s(
  text, text, extensions.vector, integer, text, text
);

CREATE FUNCTION public.rpc_buscar_candidatos_servicos_s2s(
  p_wa_user_id text,
  p_consulta text,
  p_embedding_pergunta extensions.vector(384) DEFAULT NULL,
  p_limite integer DEFAULT 30,
  p_sessao_token text DEFAULT NULL,
  p_token_s2s text DEFAULT NULL
) RETURNS TABLE (
  cadastro_id uuid,
  servico_id uuid,
  nome text,
  empresa text,
  cargo text,
  servico text,
  categoria text,
  descricao text,
  problemas_resolvidos text,
  especialidades text[],
  cidade text,
  estado text,
  site text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  score_recuperacao double precision,
  rank_lexical integer,
  rank_semantico integer,
  score_lexical double precision,
  score_semantico double precision,
  cadastro_criado_em timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'on'
AS $$
DECLARE
  v_consulta text := NULLIF(btrim(p_consulta), '');
  v_limite integer := COALESCE(p_limite, 30);
  v_pool integer;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  PERFORM private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  IF v_consulta IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: consulta.' USING ERRCODE = '23502';
  END IF;
  IF v_limite < 1 OR v_limite > 50 THEN
    RAISE EXCEPTION 'Parametro invalido: limite deve estar entre 1 e 50.' USING ERRCODE = '22023';
  END IF;

  v_pool := LEAST(GREATEST(v_limite * 3, 30), 100);
  PERFORM set_config('app.session_pesquisa_empresarios', 'true', true);

  RETURN QUERY
  WITH elegiveis AS MATERIALIZED (
    SELECT
      c.id AS cadastro_id,
      cs.id AS servico_id,
      c.nome,
      c.nome_preferido,
      c.empresa,
      c.cargo,
      cs.nome AS servico,
      cs.categoria_nome AS categoria,
      cs.descricao,
      cs.problemas_resolvidos,
      cs.especialidades,
      COALESCE(cs.cidade, c.cidade) AS cidade,
      COALESCE(cs.estado, c.estado) AS estado,
      c.site,
      c.telefone_enc,
      c.email_enc,
      c.instagram_enc,
      c.linkedin_enc,
      c.publicar_telefone,
      c.publicar_email,
      c.publicar_instagram,
      c.publicar_linkedin,
      c.created_at AS cadastro_criado_em,
      cs.documento_fts,
      cs.embedding
    FROM private.cadastro c
    INNER JOIN private.cadastro_servicos cs ON cs.cadastro_id = c.id
    WHERE c.status = 'aprovado'
      AND c.perfil_ativo
      AND c.cadastro_concluido_em IS NOT NULL
      AND c.autoriza_publicacao
      AND cs.ativo
      AND cs.publicado
      AND cs.status_indexacao = 'indexado'
  ),
  parametros AS (
    SELECT websearch_to_tsquery('portuguese', v_consulta) AS consulta_fts
  ),
  lexical_base AS MATERIALIZED (
    SELECT
      e.servico_id,
      ts_rank_cd(e.documento_fts, p.consulta_fts, 32)::double precision AS score_lexical
    FROM elegiveis e
    CROSS JOIN parametros p
    WHERE e.documento_fts @@ p.consulta_fts
    ORDER BY score_lexical DESC, e.servico_id
    LIMIT v_pool
  ),
  lexicais AS (
    SELECT
      lb.servico_id,
      (row_number() OVER (ORDER BY lb.score_lexical DESC, lb.servico_id))::integer AS rank_lexical,
      lb.score_lexical
    FROM lexical_base lb
  ),
  semantico_base AS MATERIALIZED (
    SELECT
      e.servico_id,
      greatest(0::double precision, least(1::double precision,
        1 - (e.embedding <=> p_embedding_pergunta)
      )) AS score_semantico
    FROM elegiveis e
    WHERE p_embedding_pergunta IS NOT NULL
      AND e.embedding IS NOT NULL
    ORDER BY e.embedding <=> p_embedding_pergunta, e.servico_id
    LIMIT v_pool
  ),
  semanticos AS (
    SELECT
      sb.servico_id,
      (row_number() OVER (ORDER BY sb.score_semantico DESC, sb.servico_id))::integer AS rank_semantico,
      sb.score_semantico
    FROM semantico_base sb
  ),
  ids AS (
    SELECT l.servico_id FROM lexicais l
    UNION
    SELECT s.servico_id FROM semanticos s
  ),
  fusionados AS (
    SELECT
      ids.servico_id,
      l.rank_lexical,
      s.rank_semantico,
      COALESCE(l.score_lexical, 0::double precision) AS score_lexical,
      COALESCE(s.score_semantico, 0::double precision) AS score_semantico,
      (
        CASE WHEN l.rank_lexical IS NULL THEN 0 ELSE 1::double precision / (60 + l.rank_lexical) END
        + CASE WHEN s.rank_semantico IS NULL THEN 0 ELSE 1::double precision / (60 + s.rank_semantico) END
      ) AS score_recuperacao
    FROM ids
    LEFT JOIN lexicais l ON l.servico_id = ids.servico_id
    LEFT JOIN semanticos s ON s.servico_id = ids.servico_id
  )
  SELECT
    e.cadastro_id,
    e.servico_id,
    COALESCE(NULLIF(e.nome_preferido, ''), e.nome),
    e.empresa,
    e.cargo,
    e.servico,
    e.categoria,
    e.descricao,
    e.problemas_resolvidos,
    e.especialidades,
    e.cidade,
    e.estado,
    e.site,
    CASE WHEN e.publicar_telefone AND e.telefone_enc IS NOT NULL THEN private.decrypt_value(e.telefone_enc) END,
    CASE WHEN e.publicar_email AND e.email_enc IS NOT NULL THEN private.decrypt_value(e.email_enc) END,
    CASE WHEN e.publicar_instagram AND e.instagram_enc IS NOT NULL THEN private.decrypt_value(e.instagram_enc) END,
    CASE WHEN e.publicar_linkedin AND e.linkedin_enc IS NOT NULL THEN private.decrypt_value(e.linkedin_enc) END,
    f.score_recuperacao,
    f.rank_lexical,
    f.rank_semantico,
    f.score_lexical,
    f.score_semantico,
    e.cadastro_criado_em
  FROM fusionados f
  INNER JOIN elegiveis e ON e.servico_id = f.servico_id
  ORDER BY f.score_recuperacao DESC, f.score_semantico DESC,
    f.score_lexical DESC, e.cadastro_criado_em ASC, e.servico_id
  LIMIT v_limite;
END;
$$;

ALTER FUNCTION public.rpc_buscar_candidatos_servicos_s2s(
  text, text, extensions.vector, integer, text, text
) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(
  text, text, extensions.vector, integer, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(
  text, text, extensions.vector, integer, text, text
) TO service_role;

-- Revalida resultados salvos antes de uma resposta "mostrar mais". A ordenacao
-- original fica no n8n; esta RPC somente remove itens que deixaram de ser publicos.
CREATE OR REPLACE FUNCTION public.rpc_validar_empresarios_publicados_s2s(
  p_wa_user_id text,
  p_servico_ids uuid[],
  p_sessao_token text,
  p_token_s2s text
) RETURNS TABLE (
  cadastro_id uuid,
  servico_id uuid,
  nome text,
  empresa text,
  servico text,
  categoria text,
  descricao text,
  cidade text,
  estado text,
  site text,
  telefone text,
  email text,
  instagram text,
  linkedin text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  PERFORM private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);
  PERFORM set_config('app.session_pesquisa_empresarios', 'true', true);

  RETURN QUERY
  SELECT
    c.id,
    cs.id,
    COALESCE(NULLIF(c.nome_preferido, ''), c.nome),
    c.empresa,
    cs.nome,
    cs.categoria_nome,
    cs.descricao,
    COALESCE(cs.cidade, c.cidade),
    COALESCE(cs.estado, c.estado),
    c.site,
    CASE WHEN c.publicar_telefone AND c.telefone_enc IS NOT NULL THEN private.decrypt_value(c.telefone_enc) END,
    CASE WHEN c.publicar_email AND c.email_enc IS NOT NULL THEN private.decrypt_value(c.email_enc) END,
    CASE WHEN c.publicar_instagram AND c.instagram_enc IS NOT NULL THEN private.decrypt_value(c.instagram_enc) END,
    CASE WHEN c.publicar_linkedin AND c.linkedin_enc IS NOT NULL THEN private.decrypt_value(c.linkedin_enc) END
  FROM private.cadastro c
  INNER JOIN private.cadastro_servicos cs ON cs.cadastro_id = c.id
  WHERE cs.id = ANY(COALESCE(p_servico_ids, '{}'::uuid[]))
    AND c.status = 'aprovado'
    AND c.perfil_ativo
    AND c.cadastro_concluido_em IS NOT NULL
    AND c.autoriza_publicacao
    AND cs.ativo
    AND cs.publicado
    AND cs.status_indexacao = 'indexado';
END;
$$;

ALTER FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  TO service_role;

COMMENT ON TABLE private.cadastro_servicos IS
  'Catalogo pesquisavel de servicos publicados, com indice textual e embedding proprios.';
COMMENT ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(
  text, text, extensions.vector, integer, text, text
) IS 'Recupera candidatos por busca textual e vetorial combinadas por RRF; o reranking ocorre no n8n.';

-- ---------------------------------------------------------------------------
-- Visibilidade administrativa. O painel continua somente consultivo para os
-- cadastros e agora mostra a situacao da publicacao e da indexacao.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS cadastro_admin_docs_select ON private.cadastro;
CREATE POLICY cadastro_admin_docs_select ON private.cadastro
FOR SELECT TO private_rpc_executor
USING (private.kb_admin_request());

DROP POLICY IF EXISTS cadastro_servicos_admin_docs_select ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_admin_docs_select ON private.cadastro_servicos
FOR SELECT TO private_rpc_executor
USING (private.kb_admin_request());

DROP FUNCTION IF EXISTS public.rpc_admin_listar_cadastros(text, integer, integer);
CREATE FUNCTION public.rpc_admin_listar_cadastros(
  p_busca text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS TABLE (
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  empresa text,
  cargo text,
  status text,
  perfil_ativo boolean,
  autoriza_publicacao boolean,
  cadastro_concluido_em timestamptz,
  total_servicos bigint,
  servicos_publicados bigint,
  documentos_indexados bigint,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_busca text := NULLIF(btrim(p_busca), '');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  PERFORM private.validar_admin_profile('admin_docs');

  RETURN QUERY
  SELECT
    c.id,
    c.nome,
    c.tipo,
    private.decrypt_value(c.telefone_enc),
    private.decrypt_value(c.email_enc),
    c.empresa,
    c.cargo,
    c.status,
    c.perfil_ativo,
    c.autoriza_publicacao,
    c.cadastro_concluido_em,
    count(DISTINCT cs.id)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.ativo AND cs.publicado)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.status_indexacao = 'indexado')::bigint,
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  LEFT JOIN private.cadastro_servicos cs ON cs.cadastro_id = c.id
  WHERE v_busca IS NULL
     OR c.nome ILIKE '%' || v_busca || '%'
     OR c.empresa ILIKE '%' || v_busca || '%'
     OR c.cargo ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.telefone_enc) ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.email_enc) ILIKE '%' || v_busca || '%'
  GROUP BY c.id
  ORDER BY c.created_at DESC, c.id
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

ALTER FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer)
  TO authenticated;

REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;

