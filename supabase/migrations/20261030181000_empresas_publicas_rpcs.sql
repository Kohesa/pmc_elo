-- Contratos publicos da separacao cadastro (pessoa privada) x empresa (ficha publica).
-- Nenhuma RPC de pesquisa retorna campos da tabela private.cadastro.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

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
  empresa_id uuid,
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
  v_empresa_id uuid;
  v_servico_id uuid;
  v_estado text := upper(NULLIF(btrim(p_estado), ''));
  v_categoria_nome text := COALESCE(NULLIF(btrim(p_categoria), ''), btrim(p_servico));
  v_agora timestamptz := now();
  v_descricao_busca text;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'processar_base_conhecimento');
  PERFORM set_config('app.session_importacao_empresarios', 'true', true);
  PERFORM set_config('app.session_importacao_planilha', 'true', true);

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
      nome, nome_preferido, tipo, cargo, telefone_enc, telefone_hash, email_enc,
      status, perfil_ativo, cadastro_concluido_em, created_at, updated_at
    ) VALUES (
      btrim(p_nome), NULLIF(btrim(p_nome_preferido), ''), 'Pessoa', NULLIF(btrim(p_cargo), ''),
      CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_telefone)) END,
      CASE WHEN NULLIF(btrim(p_telefone), '') IS NULL THEN NULL ELSE private.hash_value(btrim(p_telefone)) END,
      CASE WHEN NULLIF(btrim(p_email), '') IS NULL THEN NULL ELSE private.encrypt_value(btrim(p_email)) END,
      'aprovado', true, v_agora, COALESCE(p_created_at, v_agora), v_agora
    ) RETURNING id INTO v_cadastro_id;
  ELSE
    UPDATE private.cadastro c
       SET nome = btrim(p_nome),
           nome_preferido = NULLIF(btrim(p_nome_preferido), ''),
           cargo = NULLIF(btrim(p_cargo), ''),
           telefone_enc = CASE
             WHEN c.telefone_enc IS NULL AND NULLIF(btrim(p_telefone), '') IS NOT NULL
               THEN private.encrypt_value(btrim(p_telefone))
             ELSE c.telefone_enc
           END,
           telefone_hash = CASE
             WHEN c.telefone_hash IS NULL AND NULLIF(btrim(p_telefone), '') IS NOT NULL
               THEN private.hash_value(btrim(p_telefone))
             ELSE c.telefone_hash
           END,
           email_enc = CASE
             WHEN NULLIF(btrim(p_email), '') IS NOT NULL THEN private.encrypt_value(btrim(p_email))
             ELSE c.email_enc
           END,
           status = 'aprovado',
           perfil_ativo = true,
           cadastro_concluido_em = COALESCE(c.cadastro_concluido_em, v_agora),
           updated_at = v_agora
     WHERE c.id = p_cadastro_id
     RETURNING c.id INTO v_cadastro_id;

    IF v_cadastro_id IS NULL THEN
      RAISE EXCEPTION 'Cadastro informado nao encontrado.' USING ERRCODE = '02000';
    END IF;
  END IF;

  SELECT e.id
    INTO v_empresa_id
    FROM private.empresas e
   WHERE e.cadastro_responsavel_id = v_cadastro_id
     AND lower(btrim(e.nome)) = lower(btrim(p_empresa))
   ORDER BY e.created_at, e.id
   LIMIT 1;

  IF v_empresa_id IS NULL THEN
    INSERT INTO private.empresas (
      cadastro_responsavel_id, nome, descricao_negocio, setor, cidade, estado,
      telefone_publico, email_publico, links_publicos, ativo, publicado,
      autorizado_publicacao_em, publicacao_termo_versao, origem_carga,
      created_at, updated_at
    ) VALUES (
      v_cadastro_id, btrim(p_empresa), btrim(p_descricao), NULLIF(btrim(p_setor), ''),
      NULLIF(btrim(p_cidade), ''), v_estado,
      NULLIF(btrim(p_telefone), ''),
      NULLIF(btrim(p_email), ''),
      private.normalizar_links_publicos(
        p_site,
        CASE WHEN COALESCE(p_publicar_instagram, false) THEN p_instagram END,
        CASE WHEN COALESCE(p_publicar_linkedin, false) THEN p_linkedin END
      ),
      true, true, v_agora,
      COALESCE(NULLIF(btrim(p_versao_termo), ''), 'carga-controlada-v1'),
      'controlada', COALESCE(p_created_at, v_agora), v_agora
    ) RETURNING id INTO v_empresa_id;
  ELSE
    UPDATE private.empresas e
       SET descricao_negocio = btrim(p_descricao),
           setor = NULLIF(btrim(p_setor), ''),
           cidade = NULLIF(btrim(p_cidade), ''),
           estado = v_estado,
           telefone_publico = NULLIF(btrim(p_telefone), ''),
           email_publico = NULLIF(btrim(p_email), ''),
           links_publicos = private.normalizar_links_publicos(
             p_site,
             CASE WHEN COALESCE(p_publicar_instagram, false) THEN p_instagram END,
             CASE WHEN COALESCE(p_publicar_linkedin, false) THEN p_linkedin END
           ),
           ativo = true,
           publicado = true,
           autorizado_publicacao_em = COALESCE(e.autorizado_publicacao_em, v_agora),
           publicacao_termo_versao = COALESCE(NULLIF(btrim(p_versao_termo), ''), e.publicacao_termo_versao),
           updated_at = v_agora
     WHERE e.id = v_empresa_id;
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
   WHERE cs.empresa_id = v_empresa_id
     AND lower(btrim(cs.nome)) = lower(btrim(p_servico))
   LIMIT 1;

  IF v_servico_id IS NULL THEN
    INSERT INTO private.cadastro_servicos (
      empresa_id, nome, descricao, problemas_resolvidos, especialidades,
      categoria_nome, categoria_aliases, cidade, estado, descricao_busca,
      status_indexacao, embedding, embedding_model, indexed_at, erro_indexacao,
      ativo, publicado, publicado_em, origem_carga
    ) VALUES (
      v_empresa_id, btrim(p_servico), btrim(p_descricao), NULLIF(btrim(p_problemas_resolvidos), ''),
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
           publicado_em = COALESCE(cs.publicado_em, v_agora),
           updated_at = v_agora
     WHERE cs.id = v_servico_id;
  END IF;

  RETURN QUERY SELECT v_cadastro_id, v_empresa_id, v_servico_id, 'pendente'::text;
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
  empresa_id uuid,
  servico_id uuid,
  empresa text,
  servico text,
  categoria text,
  descricao_negocio text,
  descricao text,
  problemas_resolvidos text,
  especialidades text[],
  cidade text,
  estado text,
  telefone text,
  email text,
  links_publicos jsonb,
  score_recuperacao double precision,
  rank_lexical integer,
  rank_semantico integer,
  score_lexical double precision,
  score_semantico double precision,
  empresa_criada_em timestamptz
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
      e.id AS empresa_id,
      cs.id AS servico_id,
      e.nome AS empresa,
      cs.nome AS servico,
      cs.categoria_nome AS categoria,
      e.descricao_negocio,
      cs.descricao,
      cs.problemas_resolvidos,
      cs.especialidades,
      COALESCE(cs.cidade, e.cidade) AS cidade,
      COALESCE(cs.estado, e.estado) AS estado,
      e.telefone_publico AS telefone,
      e.email_publico AS email,
      e.links_publicos,
      e.created_at AS empresa_criada_em,
      cs.documento_fts,
      cs.embedding
    FROM private.empresas e
    INNER JOIN private.cadastro_servicos cs ON cs.empresa_id = e.id
    WHERE e.ativo
      AND e.publicado
      AND e.autorizado_publicacao_em IS NOT NULL
      AND cs.ativo
      AND cs.publicado
      AND cs.status_indexacao = 'indexado'
  ),
  parametros AS (
    SELECT websearch_to_tsquery('portuguese', v_consulta) AS consulta_fts
  ),
  lexical_base AS MATERIALIZED (
    SELECT e.servico_id,
      ts_rank_cd(e.documento_fts, p.consulta_fts, 32)::double precision AS score_lexical
    FROM elegiveis e CROSS JOIN parametros p
    WHERE e.documento_fts @@ p.consulta_fts
    ORDER BY score_lexical DESC, e.servico_id
    LIMIT v_pool
  ),
  lexicais AS (
    SELECT lb.servico_id,
      (row_number() OVER (ORDER BY lb.score_lexical DESC, lb.servico_id))::integer AS rank_lexical,
      lb.score_lexical
    FROM lexical_base lb
  ),
  semantico_base AS MATERIALIZED (
    SELECT e.servico_id,
      greatest(0::double precision, least(1::double precision, 1 - (e.embedding <=> p_embedding_pergunta))) AS score_semantico
    FROM elegiveis e
    WHERE p_embedding_pergunta IS NOT NULL AND e.embedding IS NOT NULL
    ORDER BY e.embedding <=> p_embedding_pergunta, e.servico_id
    LIMIT v_pool
  ),
  semanticos AS (
    SELECT sb.servico_id,
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
    SELECT ids.servico_id, l.rank_lexical, s.rank_semantico,
      COALESCE(l.score_lexical, 0::double precision) AS score_lexical,
      COALESCE(s.score_semantico, 0::double precision) AS score_semantico,
      (CASE WHEN l.rank_lexical IS NULL THEN 0 ELSE 1::double precision / (60 + l.rank_lexical) END
       + CASE WHEN s.rank_semantico IS NULL THEN 0 ELSE 1::double precision / (60 + s.rank_semantico) END) AS score_recuperacao
    FROM ids
    LEFT JOIN lexicais l ON l.servico_id = ids.servico_id
    LEFT JOIN semanticos s ON s.servico_id = ids.servico_id
  )
  SELECT e.empresa_id, e.servico_id, e.empresa, e.servico, e.categoria,
    e.descricao_negocio, e.descricao, e.problemas_resolvidos, e.especialidades,
    e.cidade, e.estado, e.telefone, e.email, e.links_publicos,
    f.score_recuperacao, f.rank_lexical, f.rank_semantico,
    f.score_lexical, f.score_semantico, e.empresa_criada_em
  FROM fusionados f
  INNER JOIN elegiveis e ON e.servico_id = f.servico_id
  ORDER BY f.score_recuperacao DESC, f.score_semantico DESC,
    f.score_lexical DESC, e.empresa_criada_em ASC, e.servico_id
  LIMIT v_limite;
END;
$$;

ALTER FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text)
  TO service_role;

DROP FUNCTION IF EXISTS public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text);
CREATE FUNCTION public.rpc_validar_empresarios_publicados_s2s(
  p_wa_user_id text,
  p_servico_ids uuid[],
  p_sessao_token text,
  p_token_s2s text
) RETURNS TABLE (
  empresa_id uuid,
  servico_id uuid,
  empresa text,
  servico text,
  categoria text,
  descricao_negocio text,
  descricao text,
  problemas_resolvidos text,
  especialidades text[],
  cidade text,
  estado text,
  telefone text,
  email text,
  links_publicos jsonb,
  empresa_criada_em timestamptz
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
  SELECT e.id, cs.id, e.nome, cs.nome, cs.categoria_nome,
    e.descricao_negocio, cs.descricao, cs.problemas_resolvidos, cs.especialidades,
    COALESCE(cs.cidade, e.cidade), COALESCE(cs.estado, e.estado),
    e.telefone_publico, e.email_publico, e.links_publicos, e.created_at
  FROM private.empresas e
  INNER JOIN private.cadastro_servicos cs ON cs.empresa_id = e.id
  WHERE cs.id = ANY(COALESCE(p_servico_ids, '{}'::uuid[]))
    AND e.ativo AND e.publicado AND e.autorizado_publicacao_em IS NOT NULL
    AND cs.ativo AND cs.publicado
    AND cs.status_indexacao = 'indexado';
END;
$$;

ALTER FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text)
  TO service_role;

DROP FUNCTION IF EXISTS public.rpc_reservar_servicos_indexacao_pendentes_s2s(text, integer);
CREATE FUNCTION public.rpc_reservar_servicos_indexacao_pendentes_s2s(
  p_token_s2s text,
  p_limite integer DEFAULT 100
) RETURNS TABLE (servico_id uuid, descricao_busca text, tentativa integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, extensions
AS $$
DECLARE
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 100), 1), 100);
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'processar_base_conhecimento');
  PERFORM set_config('app.session_importacao_empresarios', 'true', true);
  PERFORM set_config('app.session_pesquisa_empresarios', 'true', true);

  RETURN QUERY
  WITH candidatos AS (
    SELECT cs.id
    FROM private.cadastro_servicos cs
    JOIN private.empresas e ON e.id = cs.empresa_id
    WHERE cs.ativo AND cs.publicado
      AND e.ativo AND e.publicado AND e.autorizado_publicacao_em IS NOT NULL
      AND NULLIF(btrim(cs.descricao_busca), '') IS NOT NULL
      AND cs.tentativas_indexacao < 5
      AND (
        cs.status_indexacao IN ('pendente', 'erro')
        OR (cs.status_indexacao = 'indexando'
          AND COALESCE(cs.ultima_tentativa_indexacao, cs.updated_at) < clock_timestamp() - interval '30 minutes')
      )
    ORDER BY CASE cs.status_indexacao WHEN 'pendente' THEN 0 WHEN 'erro' THEN 1 ELSE 2 END,
      COALESCE(cs.ultima_tentativa_indexacao, cs.created_at), cs.created_at, cs.id
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
    RETURNING cs.id, cs.descricao_busca, cs.tentativas_indexacao
  )
  SELECT r.id, r.descricao_busca, r.tentativas_indexacao
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

-- Painel: contatos privados e empresas publicas sao consultados separadamente.
DROP FUNCTION IF EXISTS public.rpc_admin_listar_cadastros(text, integer, integer);
CREATE FUNCTION public.rpc_admin_listar_cadastros(
  p_busca text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS TABLE (
  id uuid, nome text, tipo text, telefone text, email text, empresa text, cargo text,
  status text, perfil_ativo boolean, autoriza_publicacao boolean,
  cadastro_concluido_em timestamptz, total_servicos bigint,
  servicos_publicados bigint, documentos_indexados bigint,
  created_at timestamptz, updated_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_busca text := NULLIF(btrim(p_busca), '');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  PERFORM private.validar_admin_profile('admin_docs');
  PERFORM set_config('app.session_admin_operacao', 'true', true);

  RETURN QUERY
  SELECT c.id, c.nome, c.tipo,
    private.decrypt_value(c.telefone_enc), private.decrypt_value(c.email_enc),
    string_agg(DISTINCT e.nome, ', ' ORDER BY e.nome), c.cargo, c.status,
    c.perfil_ativo, bool_or(COALESCE(e.publicado, false)), c.cadastro_concluido_em,
    count(DISTINCT cs.id)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.ativo AND cs.publicado)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.status_indexacao = 'indexado')::bigint,
    c.created_at, c.updated_at
  FROM private.cadastro c
  LEFT JOIN private.empresas e ON e.cadastro_responsavel_id = c.id
  LEFT JOIN private.cadastro_servicos cs ON cs.empresa_id = e.id
  WHERE v_busca IS NULL
     OR c.nome ILIKE '%' || v_busca || '%'
     OR c.cargo ILIKE '%' || v_busca || '%'
     OR e.nome ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.telefone_enc) ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.email_enc) ILIKE '%' || v_busca || '%'
  GROUP BY c.id
  ORDER BY c.created_at DESC, c.id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

ALTER FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) TO authenticated;

DROP FUNCTION IF EXISTS public.rpc_admin_listar_empresas(text, integer, integer);
CREATE FUNCTION public.rpc_admin_listar_empresas(
  p_busca text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS TABLE (
  id uuid,
  nome text,
  descricao_negocio text,
  setor text,
  cidade text,
  estado text,
  telefone text,
  email text,
  links_publicos jsonb,
  ativo boolean,
  publicado boolean,
  responsavel_nome text,
  total_servicos bigint,
  servicos_publicados bigint,
  servicos_indexados bigint,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_busca text := NULLIF(btrim(p_busca), '');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  PERFORM private.validar_admin_profile('admin_docs');
  PERFORM set_config('app.session_admin_operacao', 'true', true);

  RETURN QUERY
  SELECT e.id, e.nome, e.descricao_negocio, e.setor, e.cidade, e.estado,
    e.telefone_publico, e.email_publico, e.links_publicos, e.ativo, e.publicado,
    COALESCE(NULLIF(c.nome_preferido, ''), c.nome),
    count(DISTINCT cs.id)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.ativo AND cs.publicado)::bigint,
    count(DISTINCT cs.id) FILTER (WHERE cs.status_indexacao = 'indexado')::bigint,
    e.created_at, e.updated_at
  FROM private.empresas e
  LEFT JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
  LEFT JOIN private.cadastro_servicos cs ON cs.empresa_id = e.id
  WHERE v_busca IS NULL
     OR e.nome ILIKE '%' || v_busca || '%'
     OR e.descricao_negocio ILIKE '%' || v_busca || '%'
     OR e.setor ILIKE '%' || v_busca || '%'
     OR e.telefone_publico ILIKE '%' || v_busca || '%'
     OR e.email_publico ILIKE '%' || v_busca || '%'
  GROUP BY e.id, c.id
  ORDER BY e.created_at DESC, e.id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

ALTER FUNCTION public.rpc_admin_listar_empresas(text, integer, integer) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_empresas(text, integer, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_listar_empresas(text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.rpc_admin_listar_empresas(text, integer, integer)
  IS 'Lista somente a ficha comercial publica e os indicadores de servicos; nao projeta contatos privados.';
COMMENT ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text)
  IS 'Pesquisa servicos e retorna somente dados autorizados da ficha publica da empresa.';

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
