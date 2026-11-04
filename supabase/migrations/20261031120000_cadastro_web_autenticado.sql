-- Cadastro web autenticado da Elo.
-- A propriedade do cadastro vem da conta autenticada por e-mail e senha no Supabase Auth.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS origem_cadastro text,
  ADD COLUMN IF NOT EXISTS etapa_cadastro text,
  ADD COLUMN IF NOT EXISTS cadastro_iniciado_em timestamptz,
  ADD COLUMN IF NOT EXISTS email_verificado_em timestamptz,
  ADD COLUMN IF NOT EXISTS email_hash text;

UPDATE private.cadastro
   SET email_hash = private.hash_value(lower(btrim(private.decrypt_value(email_enc))))
 WHERE email_enc IS NOT NULL
   AND email_hash IS NULL;

CREATE INDEX IF NOT EXISTS ix_cadastro_email_hash
  ON private.cadastro (email_hash)
  WHERE email_hash IS NOT NULL;

ALTER TABLE private.cadastro DROP CONSTRAINT IF EXISTS cadastro_status_check;
ALTER TABLE private.cadastro
  ADD CONSTRAINT cadastro_status_check
  CHECK (status IN ('em_andamento', 'aprovado', 'inativo', 'bloqueado'));

CREATE UNIQUE INDEX IF NOT EXISTS ux_cadastro_auth_user_id
  ON private.cadastro (auth_user_id)
  WHERE auth_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS private.cadastro_auditoria (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cadastro_id uuid REFERENCES private.cadastro(id) ON DELETE SET NULL,
  auth_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  evento text NOT NULL,
  origem text NOT NULL,
  conversation_id bigint,
  ocorreu_em timestamptz NOT NULL DEFAULT now(),
  metadados jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT cadastro_auditoria_metadados_objeto
    CHECK (jsonb_typeof(metadados) = 'object')
);

ALTER TABLE private.cadastro_auditoria ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON private.cadastro_auditoria TO private_rpc_executor;
GRANT USAGE, SELECT ON SEQUENCE private.cadastro_auditoria_id_seq TO private_rpc_executor;

DROP POLICY IF EXISTS cadastro_operacao_conversacional_select ON private.cadastro;
CREATE POLICY cadastro_operacao_conversacional_select ON private.cadastro
FOR SELECT TO private_rpc_executor
USING (current_setting('app.session_cadastro_operacao', true) = 'true');

DROP POLICY IF EXISTS cadastro_operacao_conversacional_insert ON private.cadastro;
CREATE POLICY cadastro_operacao_conversacional_insert ON private.cadastro
FOR INSERT TO private_rpc_executor
WITH CHECK (current_setting('app.session_cadastro_operacao', true) = 'true');

DROP POLICY IF EXISTS cadastro_operacao_conversacional_update ON private.cadastro;
CREATE POLICY cadastro_operacao_conversacional_update ON private.cadastro
FOR UPDATE TO private_rpc_executor
USING (current_setting('app.session_cadastro_operacao', true) = 'true')
WITH CHECK (current_setting('app.session_cadastro_operacao', true) = 'true');

DROP POLICY IF EXISTS empresas_cadastro_operacao ON private.empresas;
CREATE POLICY empresas_cadastro_operacao ON private.empresas
FOR ALL TO private_rpc_executor
USING (current_setting('app.session_cadastro_operacao', true) = 'true')
WITH CHECK (current_setting('app.session_cadastro_operacao', true) = 'true');

DROP POLICY IF EXISTS cadastro_servicos_cadastro_operacao ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_cadastro_operacao ON private.cadastro_servicos
FOR ALL TO private_rpc_executor
USING (current_setting('app.session_cadastro_operacao', true) = 'true')
WITH CHECK (current_setting('app.session_cadastro_operacao', true) = 'true');

DROP POLICY IF EXISTS cadastro_auditoria_operacao ON private.cadastro_auditoria;
CREATE POLICY cadastro_auditoria_operacao ON private.cadastro_auditoria
FOR ALL TO private_rpc_executor
USING (current_setting('app.session_cadastro_operacao', true) = 'true')
WITH CHECK (current_setting('app.session_cadastro_operacao', true) = 'true');

CREATE OR REPLACE FUNCTION private.normalizar_texto_cadastro(p_texto text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO pg_catalog
AS $$
  SELECT translate(
    lower(COALESCE(btrim(p_texto), '')),
    'áàãâäéèêëíìîïóòõôöúùûüç',
    'aaaaaeeeeiiiiooooouuuuc'
  );
$$;

CREATE OR REPLACE FUNCTION private.cadastro_resposta_sim(p_texto text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path TO private, pg_catalog
AS $$
  SELECT private.normalizar_texto_cadastro(p_texto) ~ '^(sim|s|aceito|autorizo|confirmo|quero)$';
$$;

CREATE OR REPLACE FUNCTION private.cadastro_resposta_nao(p_texto text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path TO private, pg_catalog
AS $$
  SELECT private.normalizar_texto_cadastro(p_texto) ~ '^(nao|n|recuso|cancelar)$';
$$;

CREATE OR REPLACE FUNCTION private.cadastro_json_descriptografado(p_valor text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO private, pg_catalog
AS $$
BEGIN
  IF p_valor IS NULL OR btrim(p_valor) = '' THEN
    RETURN '{}'::jsonb;
  END IF;
  RETURN private.decrypt_value(p_valor)::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN '{}'::jsonb;
END;
$$;

ALTER FUNCTION private.cadastro_json_descriptografado(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.cadastro_json_descriptografado(text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.cadastro_identidade_auth_atual()
RETURNS TABLE(user_id uuid, telefone text, email text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO auth, public, pg_catalog
AS $$
  SELECT u.id, u.phone, u.email
    FROM auth.users u
   WHERE u.id = public.request_jwt_sub()
     AND u.email IS NOT NULL
     AND u.email IS NOT NULL;
$$;

ALTER FUNCTION private.cadastro_identidade_auth_atual() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.cadastro_identidade_auth_atual() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.cadastro_identidade_auth_atual() TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.registrar_auditoria_cadastro(
  p_cadastro_id uuid,
  p_auth_user_id uuid,
  p_evento text,
  p_origem text,
  p_conversation_id bigint DEFAULT NULL,
  p_metadados jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO private, pg_catalog
SET row_security TO on
AS $$
BEGIN
  PERFORM set_config('app.session_cadastro_operacao', 'true', true);
  INSERT INTO private.cadastro_auditoria (
    cadastro_id, auth_user_id, evento, origem, conversation_id, metadados
  ) VALUES (
    p_cadastro_id,
    p_auth_user_id,
    left(COALESCE(p_evento, 'evento'), 80),
    left(COALESCE(p_origem, 'desconhecida'), 40),
    p_conversation_id,
    COALESCE(p_metadados, '{}'::jsonb) - 'otp' - 'token' - 'telefone' - 'email'
  );
END;
$$;

ALTER FUNCTION private.registrar_auditoria_cadastro(uuid, uuid, text, text, bigint, jsonb) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.registrar_auditoria_cadastro(uuid, uuid, text, text, bigint, jsonb) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.finalizar_cadastro_elo(
  p_cadastro_id uuid,
  p_origem text,
  p_conversation_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO private, public, extensions, pg_catalog
SET row_security TO on
AS $$
DECLARE
  v_cadastro private.cadastro%ROWTYPE;
  v_dados jsonb;
  v_empresa_id uuid;
  v_servico_id uuid;
  v_publicar boolean;
  v_publicar_telefone boolean;
  v_publicar_email boolean;
  v_empresa_telefone text;
  v_empresa_email text;
  v_links jsonb;
BEGIN
  PERFORM set_config('app.session_cadastro_operacao', 'true', true);
  SELECT * INTO v_cadastro FROM private.cadastro WHERE id = p_cadastro_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cadastro não encontrado.' USING ERRCODE = 'P0002'; END IF;
  IF v_cadastro.auth_user_id IS NULL OR v_cadastro.email_verificado_em IS NULL THEN
    RAISE EXCEPTION 'Crie e autentique o login antes de concluir.' USING ERRCODE = '42501';
  END IF;
  IF NOT v_cadastro.termos_uso_aceito OR NOT v_cadastro.politica_privacidade_aceita THEN
    RAISE EXCEPTION 'Aceite dos documentos legais não registrado.' USING ERRCODE = '42501';
  END IF;

  v_dados := private.cadastro_json_descriptografado(v_cadastro.respostas_formulario_enc);
  v_publicar := COALESCE((v_dados ->> 'autoriza_publicacao')::boolean, false);
  v_empresa_telefone := NULLIF(btrim(v_dados ->> 'empresa_telefone'), '');
  v_empresa_email := NULLIF(lower(btrim(v_dados ->> 'empresa_email')), '');
  v_publicar_telefone := v_empresa_telefone IS NOT NULL
    AND COALESCE((v_dados ->> 'publicar_telefone')::boolean, false);
  v_publicar_email := v_empresa_email IS NOT NULL
    AND COALESCE((v_dados ->> 'publicar_email')::boolean, false);
  v_links := private.normalizar_links_publicos(
    v_dados ->> 'site', v_dados ->> 'instagram', v_dados ->> 'linkedin'
  );

  INSERT INTO private.empresas (
    cadastro_responsavel_id, nome, descricao_negocio, setor, cidade, estado,
    telefone_publico, email_publico, links_publicos, ativo, publicado,
    autorizado_publicacao_em, publicacao_termo_versao, origem_carga
  ) VALUES (
    v_cadastro.id,
    COALESCE(NULLIF(btrim(v_dados ->> 'empresa_nome'), ''), v_cadastro.nome, 'Empresa sem nome'),
    NULLIF(btrim(v_dados ->> 'empresa_descricao'), ''),
    NULLIF(btrim(v_dados ->> 'setor'), ''),
    'Blumenau', 'SC',
    CASE WHEN v_publicar AND v_publicar_telefone THEN v_empresa_telefone END,
    CASE WHEN v_publicar AND v_publicar_email THEN v_empresa_email END,
    v_links,
    true, v_publicar,
    CASE WHEN v_publicar THEN now() END,
    CASE WHEN v_publicar THEN COALESCE(v_cadastro.publicacao_termo_versao, 'elo-mvp-1') END,
    p_origem
  )
  ON CONFLICT (cadastro_responsavel_id, lower(btrim(nome)))
  WHERE cadastro_responsavel_id IS NOT NULL
  DO UPDATE SET
    descricao_negocio = EXCLUDED.descricao_negocio,
    setor = EXCLUDED.setor,
    telefone_publico = EXCLUDED.telefone_publico,
    email_publico = EXCLUDED.email_publico,
    links_publicos = EXCLUDED.links_publicos,
    ativo = true,
    publicado = EXCLUDED.publicado,
    autorizado_publicacao_em = EXCLUDED.autorizado_publicacao_em,
    publicacao_termo_versao = EXCLUDED.publicacao_termo_versao,
    updated_at = now()
  RETURNING id INTO v_empresa_id;

  INSERT INTO private.cadastro_servicos (
    empresa_id, nome, descricao, problemas_resolvidos,
    categoria_nome, categoria_aliases, cidade, estado, status_indexacao,
    embedding, embedding_model, indexed_at, erro_indexacao,
    ativo, publicado, publicado_em, origem_carga
  ) VALUES (
    v_empresa_id,
    COALESCE(NULLIF(btrim(v_dados ->> 'servico_nome'), ''), 'Serviço principal'),
    COALESCE(NULLIF(btrim(v_dados ->> 'servico_descricao'), ''), NULLIF(btrim(v_dados ->> 'empresa_descricao'), ''), 'Descrição pendente'),
    NULLIF(btrim(v_dados ->> 'problemas_resolvidos'), ''),
    COALESCE(NULLIF(btrim(v_dados ->> 'setor'), ''), NULLIF(btrim(v_dados ->> 'servico_nome'), ''), 'Outros serviços'),
    ARRAY[]::text[], 'Blumenau', 'SC', 'pendente',
    NULL, NULL, NULL, NULL,
    true, v_publicar, CASE WHEN v_publicar THEN now() END, p_origem
  )
  ON CONFLICT (empresa_id, lower(btrim(nome)))
  DO UPDATE SET
    descricao = EXCLUDED.descricao,
    problemas_resolvidos = EXCLUDED.problemas_resolvidos,
    categoria_nome = EXCLUDED.categoria_nome,
    status_indexacao = 'pendente',
    embedding = NULL,
    embedding_model = NULL,
    indexed_at = NULL,
    erro_indexacao = NULL,
    ativo = true,
    publicado = EXCLUDED.publicado,
    publicado_em = EXCLUDED.publicado_em,
    updated_at = now()
  RETURNING id INTO v_servico_id;

  UPDATE private.cadastro
     SET status = 'aprovado', etapa_cadastro = 'concluido', cadastro_concluido_em = now(),
         origem_cadastro = COALESCE(origem_cadastro, p_origem),
         autoriza_publicacao = v_publicar,
         autoriza_publicacao_em = CASE WHEN v_publicar THEN now() END,
         publicacao_termo_versao = CASE WHEN v_publicar THEN COALESCE(publicacao_termo_versao, 'elo-mvp-1') END,
         publicar_telefone = v_publicar_telefone,
         publicar_email = v_publicar_email,
         updated_at = now()
   WHERE id = v_cadastro.id;

  PERFORM private.registrar_auditoria_cadastro(
    v_cadastro.id, v_cadastro.auth_user_id, 'cadastro_concluido', p_origem,
    p_conversation_id, jsonb_build_object('empresa_id', v_empresa_id, 'servico_id', v_servico_id)
  );
  RETURN jsonb_build_object('cadastro_id', v_cadastro.id, 'empresa_id', v_empresa_id, 'servico_id', v_servico_id);
END;
$$;

ALTER FUNCTION private.finalizar_cadastro_elo(uuid, text, bigint) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.finalizar_cadastro_elo(uuid, text, bigint) FROM PUBLIC, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION public.rpc_cadastro_web_salvar(p_dados jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO private, public, extensions, pg_catalog
SET row_security TO on
AS $$
DECLARE
  v_ident record;
  v_cadastro_id uuid;
  v_cadastro private.cadastro%ROWTYPE;
  v_dados jsonb;
  v_email_hash text;
  v_telefone text;
  v_empresa_telefone text;
  v_empresa_email text;
BEGIN
  PERFORM set_config('app.session_cadastro_operacao', 'true', true);
  SELECT * INTO v_ident FROM private.cadastro_identidade_auth_atual();
  IF v_ident.user_id IS NULL THEN RAISE EXCEPTION 'Autenticação por e-mail e senha é obrigatória.' USING ERRCODE = '42501'; END IF;
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
  IF COALESCE((p_dados ->> 'aceita_termos')::boolean, false) IS NOT TRUE THEN RAISE EXCEPTION 'É necessário aceitar os documentos legais.' USING ERRCODE = '22023'; END IF;
  IF NULLIF(btrim(p_dados ->> 'nome'), '') IS NULL OR NULLIF(btrim(p_dados ->> 'empresa_nome'), '') IS NULL OR NULLIF(btrim(p_dados ->> 'servico_nome'), '') IS NULL THEN
    RAISE EXCEPTION 'Nome, empresa e serviço são obrigatórios.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cadastro FROM private.cadastro
   WHERE auth_user_id = v_ident.user_id
      OR email_hash = v_email_hash
      OR (email_enc IS NOT NULL AND lower(btrim(private.decrypt_value(email_enc))) = lower(btrim(v_ident.email)))
   ORDER BY (auth_user_id = v_ident.user_id) DESC, created_at LIMIT 1 FOR UPDATE;
  v_dados := jsonb_build_object(
    'nome_preferido', NULLIF(btrim(p_dados ->> 'nome_preferido'), ''),
    'empresa_nome', btrim(p_dados ->> 'empresa_nome'),
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
    'autoriza_publicacao', COALESCE((p_dados ->> 'autoriza_publicacao')::boolean, false),
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
    IF v_cadastro.auth_user_id IS NOT NULL AND v_cadastro.auth_user_id <> v_ident.user_id THEN RAISE EXCEPTION 'E-mail vinculado a outra conta.' USING ERRCODE = '23505'; END IF;
    UPDATE private.cadastro SET
      auth_user_id = v_ident.user_id, nome = left(btrim(p_dados ->> 'nome'), 160),
      nome_preferido = NULLIF(btrim(p_dados ->> 'nome_preferido'), ''),
      telefone_enc = CASE WHEN v_telefone IS NOT NULL AND telefone_enc IS NULL AND telefone_hash IS NULL THEN private.encrypt_value(v_telefone) ELSE telefone_enc END,
      telefone_hash = CASE WHEN v_telefone IS NOT NULL AND telefone_enc IS NULL AND telefone_hash IS NULL THEN private.hash_phone_number(v_telefone) ELSE telefone_hash END,
      email_enc = private.encrypt_value(lower(btrim(v_ident.email))), email_hash = v_email_hash,
      email_verificado_em = COALESCE(email_verificado_em, now()),
      origem_cadastro = COALESCE(origem_cadastro, 'web'), etapa_cadastro = 'finalizando', status = 'em_andamento',
      cadastro_iniciado_em = COALESCE(cadastro_iniciado_em, now()), respostas_formulario_enc = private.encrypt_value(v_dados::text),
      termos_uso_aceito = true, termos_uso_aceito_em = COALESCE(termos_uso_aceito_em, now()),
      politica_privacidade_aceita = true, politica_privacidade_aceita_em = COALESCE(politica_privacidade_aceita_em, now()),
      documentos_legais_versao = 'elo-mvp-1', updated_at = now()
    WHERE id = v_cadastro.id RETURNING * INTO v_cadastro;
  END IF;
  RETURN private.finalizar_cadastro_elo(v_cadastro.id, 'web', NULL);
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
  IF v_ident.user_id IS NULL THEN RAISE EXCEPTION 'Autenticação por e-mail e senha é obrigatória.' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_cadastro FROM private.cadastro WHERE auth_user_id = v_ident.user_id LIMIT 1;
  IF v_cadastro.id IS NULL THEN RETURN jsonb_build_object('cadastrado', false); END IF;
  SELECT * INTO v_empresa FROM private.empresas WHERE cadastro_responsavel_id = v_cadastro.id ORDER BY created_at LIMIT 1;
  v_dados := private.cadastro_json_descriptografado(v_cadastro.respostas_formulario_enc);
  RETURN jsonb_build_object(
    'cadastrado', true,
    'cadastro', jsonb_build_object(
      'id', v_cadastro.id, 'nome', v_cadastro.nome, 'nome_preferido', v_cadastro.nome_preferido,
      'email', private.decrypt_value(v_cadastro.email_enc), 'telefone', private.decrypt_value(v_cadastro.telefone_enc),
      'status', v_cadastro.status, 'etapa', v_cadastro.etapa_cadastro
    ),
    'empresa', CASE WHEN v_empresa.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_empresa.id, 'nome', v_empresa.nome, 'descricao_negocio', v_empresa.descricao_negocio,
      'setor', v_empresa.setor, 'telefone_publico', v_empresa.telefone_publico,
      'email_publico', v_empresa.email_publico, 'links_publicos', v_empresa.links_publicos,
      'telefone_contato', NULLIF(btrim(v_dados ->> 'empresa_telefone'), ''),
      'email_contato', NULLIF(btrim(v_dados ->> 'empresa_email'), ''),
      'publicado', v_empresa.publicado
    ) END,
    'servicos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', cs.id, 'nome', cs.nome, 'descricao', cs.descricao,
        'problemas_resolvidos', cs.problemas_resolvidos, 'categoria_nome', cs.categoria_nome,
        'publicado', cs.publicado, 'status_indexacao', cs.status_indexacao
      ) ORDER BY cs.created_at)
      FROM private.cadastro_servicos cs WHERE cs.empresa_id = v_empresa.id AND cs.ativo
    ), '[]'::jsonb)
  );
END;
$$;

ALTER FUNCTION public.rpc_meu_cadastro() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_meu_cadastro() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_meu_cadastro() TO authenticated;

COMMENT ON TABLE private.cadastro_auditoria IS 'Trilha sanitizada de eventos de cadastro, sem telefone, e-mail, OTP ou tokens.';

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
