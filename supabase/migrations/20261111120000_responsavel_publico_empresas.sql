ALTER TABLE private.empresas
  ADD COLUMN IF NOT EXISTS responsavel_publico text,
  ADD COLUMN IF NOT EXISTS publicar_responsavel boolean NOT NULL DEFAULT false;

ALTER TABLE private.empresas
  DROP CONSTRAINT IF EXISTS empresas_responsavel_publico_coerente;

ALTER TABLE private.empresas
  ADD CONSTRAINT empresas_responsavel_publico_coerente CHECK (
    NOT publicar_responsavel
    OR NULLIF(btrim(responsavel_publico), '') IS NOT NULL
  );

COMMENT ON COLUMN private.empresas.responsavel_publico IS
  'Nome de pessoa autorizado expressamente para exibição pública junto à empresa.';
COMMENT ON COLUMN private.empresas.publicar_responsavel IS
  'Consentimento específico para publicar responsavel_publico nas pesquisas da Elo.';

-- O PostgreSQL exige que a nova role proprietária tenha CREATE no schema
-- durante o ALTER FUNCTION ... OWNER TO. A permissão é revogada ao final.
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.rpc_cadastro_web_salvar(p_dados jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO private, public, extensions, pg_catalog
SET row_security TO on
AS $$
DECLARE
  v_ident record;
  v_cadastro private.cadastro%ROWTYPE;
  v_dados jsonb;
  v_resultado jsonb;
  v_email_hash text;
  v_telefone text;
  v_empresa_telefone text;
  v_empresa_email text;
  v_responsavel_publico text;
  v_autoriza_publicacao boolean;
  v_publicar_responsavel boolean;
BEGIN
  PERFORM set_config('app.session_cadastro_operacao', 'true', true);
  SELECT * INTO v_ident FROM private.cadastro_identidade_auth_atual();
  IF v_ident.user_id IS NULL THEN
    RAISE EXCEPTION 'Autenticação por e-mail e senha é obrigatória.' USING ERRCODE = '42501';
  END IF;

  v_email_hash := private.hash_value(lower(btrim(v_ident.email)));
  IF NULLIF(regexp_replace(COALESCE(p_dados ->> 'telefone', ''), '[^0-9]', '', 'g'), '') IS NOT NULL THEN
    v_telefone := regexp_replace(p_dados ->> 'telefone', '[^0-9]', '', 'g');
    IF length(v_telefone) IN (10, 11) THEN v_telefone := '55' || v_telefone; END IF;
    IF length(v_telefone) NOT IN (12, 13) THEN RAISE EXCEPTION 'Telefone inválido.' USING ERRCODE = '22023'; END IF;
    v_telefone := '+' || v_telefone;
  END IF;

  IF NULLIF(regexp_replace(COALESCE(p_dados ->> 'empresa_telefone', ''), '[^0-9]', '', 'g'), '') IS NOT NULL THEN
    v_empresa_telefone := regexp_replace(p_dados ->> 'empresa_telefone', '[^0-9]', '', 'g');
    IF length(v_empresa_telefone) IN (10, 11) THEN v_empresa_telefone := '55' || v_empresa_telefone; END IF;
    IF length(v_empresa_telefone) NOT IN (12, 13) THEN RAISE EXCEPTION 'Telefone comercial inválido.' USING ERRCODE = '22023'; END IF;
    v_empresa_telefone := '+' || v_empresa_telefone;
  END IF;

  v_empresa_email := NULLIF(lower(btrim(p_dados ->> 'empresa_email')), '');
  IF v_empresa_email IS NOT NULL AND v_empresa_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'E-mail comercial inválido.' USING ERRCODE = '22023';
  END IF;

  v_responsavel_publico := NULLIF(btrim(p_dados ->> 'empresa_responsavel'), '');
  IF length(COALESCE(v_responsavel_publico, '')) > 160 THEN
    RAISE EXCEPTION 'O nome do responsável público deve ter no máximo 160 caracteres.' USING ERRCODE = '22023';
  END IF;
  v_autoriza_publicacao := COALESCE((p_dados ->> 'autoriza_publicacao')::boolean, false);
  v_publicar_responsavel := v_autoriza_publicacao
    AND v_responsavel_publico IS NOT NULL
    AND COALESCE((p_dados ->> 'publicar_responsavel')::boolean, false);

  IF COALESCE((p_dados ->> 'aceita_termos')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'É necessário aceitar os documentos legais.' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(btrim(p_dados ->> 'nome'), '') IS NULL
    OR NULLIF(btrim(p_dados ->> 'empresa_nome'), '') IS NULL
    OR NULLIF(btrim(p_dados ->> 'servico_nome'), '') IS NULL THEN
    RAISE EXCEPTION 'Nome, empresa e serviço são obrigatórios.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cadastro
  FROM private.cadastro
  WHERE auth_user_id = v_ident.user_id
     OR email_hash = v_email_hash
     OR (email_enc IS NOT NULL AND lower(btrim(private.decrypt_value(email_enc))) = lower(btrim(v_ident.email)))
  ORDER BY (auth_user_id = v_ident.user_id) DESC, created_at
  LIMIT 1
  FOR UPDATE;

  v_dados := jsonb_build_object(
    'nome_preferido', NULLIF(btrim(p_dados ->> 'nome_preferido'), ''),
    'empresa_nome', btrim(p_dados ->> 'empresa_nome'),
    'empresa_responsavel', v_responsavel_publico,
    'empresa_descricao', btrim(p_dados ->> 'empresa_descricao'),
    'setor', btrim(p_dados ->> 'setor'),
    'site', NULLIF(btrim(p_dados ->> 'site'), ''),
    'instagram', NULLIF(btrim(p_dados ->> 'instagram'), ''),
    'linkedin', NULLIF(btrim(p_dados ->> 'linkedin'), ''),
    'empresa_telefone', v_empresa_telefone,
    'empresa_email', v_empresa_email,
    'servico_nome', btrim(p_dados ->> 'servico_nome'),
    'servico_descricao', btrim(p_dados ->> 'servico_descricao'),
    'problemas_resolvidos', btrim(COALESCE(p_dados ->> 'problemas_resolvidos', p_dados ->> 'servico_descricao')),
    'autoriza_publicacao', v_autoriza_publicacao,
    'publicar_responsavel', v_publicar_responsavel,
    'publicar_telefone', v_empresa_telefone IS NOT NULL
      AND COALESCE((p_dados ->> 'publicar_telefone')::boolean, false),
    'publicar_email', v_empresa_email IS NOT NULL
      AND COALESCE((p_dados ->> 'publicar_email')::boolean, false)
  );

  IF v_cadastro.id IS NULL THEN
    INSERT INTO private.cadastro (
      auth_user_id, nome, nome_preferido, tipo, status, telefone_enc, telefone_hash,
      email_enc, email_hash, origem_cadastro, etapa_cadastro, cadastro_iniciado_em,
      email_verificado_em, respostas_formulario_enc,
      termos_uso_aceito, termos_uso_aceito_em, politica_privacidade_aceita,
      politica_privacidade_aceita_em, documentos_legais_versao
    ) VALUES (
      v_ident.user_id, left(btrim(p_dados ->> 'nome'), 160), NULLIF(btrim(p_dados ->> 'nome_preferido'), ''),
      'Pessoa', 'em_andamento', CASE WHEN v_telefone IS NOT NULL THEN private.encrypt_value(v_telefone) END,
      CASE WHEN v_telefone IS NOT NULL THEN private.hash_phone_number(v_telefone) END,
      private.encrypt_value(lower(btrim(v_ident.email))), v_email_hash,
      'web', 'finalizando', now(), now(), private.encrypt_value(v_dados::text),
      true, now(), true, now(), 'elo-mvp-1'
    ) RETURNING * INTO v_cadastro;
  ELSE
    IF v_cadastro.auth_user_id IS NOT NULL AND v_cadastro.auth_user_id <> v_ident.user_id THEN
      RAISE EXCEPTION 'E-mail vinculado a outra conta.' USING ERRCODE = '23505';
    END IF;
    UPDATE private.cadastro SET
      auth_user_id = v_ident.user_id,
      nome = left(btrim(p_dados ->> 'nome'), 160),
      nome_preferido = NULLIF(btrim(p_dados ->> 'nome_preferido'), ''),
      telefone_enc = CASE WHEN v_telefone IS NOT NULL AND telefone_enc IS NULL AND telefone_hash IS NULL THEN private.encrypt_value(v_telefone) ELSE telefone_enc END,
      telefone_hash = CASE WHEN v_telefone IS NOT NULL AND telefone_enc IS NULL AND telefone_hash IS NULL THEN private.hash_phone_number(v_telefone) ELSE telefone_hash END,
      email_enc = private.encrypt_value(lower(btrim(v_ident.email))),
      email_hash = v_email_hash,
      email_verificado_em = COALESCE(email_verificado_em, now()),
      origem_cadastro = COALESCE(origem_cadastro, 'web'),
      etapa_cadastro = 'finalizando',
      status = 'em_andamento',
      cadastro_iniciado_em = COALESCE(cadastro_iniciado_em, now()),
      respostas_formulario_enc = private.encrypt_value(v_dados::text),
      termos_uso_aceito = true,
      termos_uso_aceito_em = COALESCE(termos_uso_aceito_em, now()),
      politica_privacidade_aceita = true,
      politica_privacidade_aceita_em = COALESCE(politica_privacidade_aceita_em, now()),
      documentos_legais_versao = 'elo-mvp-1',
      updated_at = now()
    WHERE id = v_cadastro.id
    RETURNING * INTO v_cadastro;
  END IF;

  v_resultado := private.finalizar_cadastro_elo(v_cadastro.id, 'web', NULL);

  UPDATE private.empresas
  SET responsavel_publico = CASE WHEN v_publicar_responsavel THEN v_responsavel_publico END,
      publicar_responsavel = v_publicar_responsavel,
      updated_at = now()
  WHERE id = (v_resultado ->> 'empresa_id')::uuid
    AND cadastro_responsavel_id = v_cadastro.id;

  RETURN v_resultado;
END;
$$;

ALTER FUNCTION public.rpc_cadastro_web_salvar(jsonb) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_cadastro_web_salvar(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cadastro_web_salvar(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_meu_cadastro()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO private, public, pg_catalog
SET row_security TO on
AS $$
DECLARE
  v_ident record;
  v_cadastro private.cadastro%ROWTYPE;
  v_empresa private.empresas%ROWTYPE;
  v_dados jsonb;
BEGIN
  PERFORM set_config('app.session_cadastro_operacao', 'true', true);
  SELECT * INTO v_ident FROM private.cadastro_identidade_auth_atual();
  IF v_ident.user_id IS NULL THEN
    RAISE EXCEPTION 'Autenticação por e-mail e senha é obrigatória.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_cadastro FROM private.cadastro WHERE auth_user_id = v_ident.user_id LIMIT 1;
  IF v_cadastro.id IS NULL THEN RETURN jsonb_build_object('cadastrado', false); END IF;
  SELECT * INTO v_empresa FROM private.empresas WHERE cadastro_responsavel_id = v_cadastro.id ORDER BY created_at LIMIT 1;
  v_dados := private.cadastro_json_descriptografado(v_cadastro.respostas_formulario_enc);

  RETURN jsonb_build_object(
    'cadastrado', true,
    'cadastro', jsonb_build_object(
      'id', v_cadastro.id,
      'nome', v_cadastro.nome,
      'nome_preferido', v_cadastro.nome_preferido,
      'email', private.decrypt_value(v_cadastro.email_enc),
      'telefone', private.decrypt_value(v_cadastro.telefone_enc),
      'status', v_cadastro.status,
      'etapa', v_cadastro.etapa_cadastro
    ),
    'empresa', CASE WHEN v_empresa.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_empresa.id,
      'nome', v_empresa.nome,
      'responsavel_contato', NULLIF(btrim(v_dados ->> 'empresa_responsavel'), ''),
      'responsavel_publico', CASE WHEN v_empresa.publicar_responsavel THEN v_empresa.responsavel_publico END,
      'publicar_responsavel', v_empresa.publicar_responsavel,
      'descricao_negocio', v_empresa.descricao_negocio,
      'setor', v_empresa.setor,
      'telefone_publico', v_empresa.telefone_publico,
      'email_publico', v_empresa.email_publico,
      'links_publicos', v_empresa.links_publicos,
      'telefone_contato', NULLIF(btrim(v_dados ->> 'empresa_telefone'), ''),
      'email_contato', NULLIF(btrim(v_dados ->> 'empresa_email'), ''),
      'publicado', v_empresa.publicado
    ) END,
    'servicos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', cs.id,
        'nome', cs.nome,
        'descricao', cs.descricao,
        'problemas_resolvidos', cs.problemas_resolvidos,
        'categoria_nome', cs.categoria_nome,
        'publicado', cs.publicado,
        'status_indexacao', cs.status_indexacao
      ) ORDER BY cs.created_at)
      FROM private.cadastro_servicos cs
      WHERE cs.empresa_id = v_empresa.id AND cs.ativo
    ), '[]'::jsonb)
  );
END;
$$;

ALTER FUNCTION public.rpc_meu_cadastro() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_meu_cadastro() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_meu_cadastro() TO authenticated;

DROP FUNCTION IF EXISTS public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text);

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
  responsavel_publico text,
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
  IF v_consulta IS NULL THEN RAISE EXCEPTION 'Campo obrigatorio ausente: consulta.' USING ERRCODE = '23502'; END IF;
  IF v_limite < 1 OR v_limite > 50 THEN RAISE EXCEPTION 'Parametro invalido: limite deve estar entre 1 e 50.' USING ERRCODE = '22023'; END IF;

  v_pool := LEAST(GREATEST(v_limite * 3, 30), 100);
  PERFORM set_config('app.session_pesquisa_empresarios', 'true', true);

  RETURN QUERY
  WITH elegiveis AS MATERIALIZED (
    SELECT
      e.id AS empresa_id,
      cs.id AS servico_id,
      e.nome AS empresa,
      CASE WHEN e.publicar_responsavel THEN e.responsavel_publico END AS responsavel_publico,
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
    WHERE e.ativo AND e.publicado AND e.autorizado_publicacao_em IS NOT NULL
      AND cs.ativo AND cs.publicado AND cs.status_indexacao = 'indexado'
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
  SELECT e.empresa_id, e.servico_id, e.empresa, e.responsavel_publico, e.servico, e.categoria,
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

ALTER FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_buscar_candidatos_servicos_s2s(text, text, extensions.vector, integer, text, text) TO service_role;

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
  responsavel_publico text,
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
  SELECT e.id, cs.id, e.nome,
    CASE WHEN e.publicar_responsavel THEN e.responsavel_publico END,
    cs.nome, cs.categoria_nome,
    e.descricao_negocio, cs.descricao, cs.problemas_resolvidos, cs.especialidades,
    COALESCE(cs.cidade, e.cidade), COALESCE(cs.estado, e.estado),
    e.telefone_publico, e.email_publico, e.links_publicos, e.created_at
  FROM private.empresas e
  INNER JOIN private.cadastro_servicos cs ON cs.empresa_id = e.id
  WHERE cs.id = ANY(COALESCE(p_servico_ids, '{}'::uuid[]))
    AND e.ativo AND e.publicado AND e.autorizado_publicacao_em IS NOT NULL
    AND cs.ativo AND cs.publicado AND cs.status_indexacao = 'indexado';
END;
$$;

ALTER FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_validar_empresarios_publicados_s2s(text, uuid[], text, text) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
