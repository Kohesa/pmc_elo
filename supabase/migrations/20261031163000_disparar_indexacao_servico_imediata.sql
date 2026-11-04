-- Dispara a fila de indexacao do n8n logo apos um servico publicado ser
-- criado ou alterado pelo cadastro web. A rotina diaria das 09h permanece
-- como contingencia para itens que nao puderem ser notificados.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

GRANT CREATE ON SCHEMA private TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.get_n8n_indexacao_servicos_webhook_config()
RETURNS TABLE (
  webhook_url text,
  auth_header text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'vault'
AS $$
DECLARE
  v_webhook_url text;
  v_auth_header text;
BEGIN
  IF current_setting('app.n8n_indexacao_servicos_config_allowed', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Acesso negado: configuracao do webhook deve ser lida somente pelo disparador de indexacao.'
      USING ERRCODE = '42501';
  END IF;

  SELECT ds.decrypted_secret
    INTO v_webhook_url
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'n8n_indexacao_servicos_webhook_url'
  LIMIT 1;

  -- O mesmo segredo Header Auth protege os webhooks internos de processamento
  -- Supabase -> n8n. Ele nunca e devolvido ao frontend nem incluido no payload.
  SELECT ds.decrypted_secret
    INTO v_auth_header
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'n8n_base_conhecimento_auth'
  LIMIT 1;

  webhook_url := NULLIF(btrim(v_webhook_url), '');
  auth_header := NULLIF(btrim(v_auth_header), '');

  IF webhook_url IS NULL THEN
    RAISE EXCEPTION 'Webhook n8n nao configurado: segredo n8n_indexacao_servicos_webhook_url ausente.'
      USING ERRCODE = '22023';
  END IF;

  IF auth_header IS NULL THEN
    RAISE EXCEPTION 'Webhook n8n nao configurado: segredo n8n_base_conhecimento_auth ausente.'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEXT;
END;
$$;

ALTER FUNCTION private.get_n8n_indexacao_servicos_webhook_config()
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.get_n8n_indexacao_servicos_webhook_config() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.get_n8n_indexacao_servicos_webhook_config() FROM anon;
REVOKE ALL ON FUNCTION private.get_n8n_indexacao_servicos_webhook_config() FROM authenticated;
REVOKE ALL ON FUNCTION private.get_n8n_indexacao_servicos_webhook_config() FROM service_role;
GRANT EXECUTE ON FUNCTION private.get_n8n_indexacao_servicos_webhook_config()
  TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.dispatch_indexacao_servico_webhook(
  p_servico_id uuid
) RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'net', 'pg_catalog'
AS $$
DECLARE
  v_webhook_url text;
  v_auth_header text;
  v_host text;
  v_request_id bigint;
  v_whitelist text[] := ARRAY[
    'host.docker.internal',
    'localhost',
    '127.0.0.1',
    'n8n.kohesa.com.br'
  ];
BEGIN
  IF p_servico_id IS NULL THEN
    RAISE EXCEPTION 'servico_id obrigatorio para disparar indexacao.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.n8n_indexacao_servicos_config_allowed', 'true', true);

  SELECT cfg.webhook_url, cfg.auth_header
    INTO v_webhook_url, v_auth_header
  FROM private.get_n8n_indexacao_servicos_webhook_config() cfg;

  PERFORM set_config('app.n8n_indexacao_servicos_config_allowed', '', true);

  v_host := lower(substring(v_webhook_url from '^https?://([^/:?#]+)'));
  IF v_host IS NULL OR NOT (v_host = ANY(v_whitelist)) THEN
    RAISE EXCEPTION 'Destino HTTP nao autorizado: dominio "%" nao permitido.', COALESCE(v_host, '<invalido>')
      USING ERRCODE = '42501';
  END IF;

  SELECT net.http_post(
    url := v_webhook_url,
    body := jsonb_build_object(
      'servico_id', p_servico_id,
      'origem', 'cadastro_web'
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-elo-internal-key', v_auth_header
    ),
    timeout_milliseconds := 5000
  ) INTO v_request_id;

  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'Falha ao enfileirar webhook n8n de indexacao do servico.'
      USING ERRCODE = '57014';
  END IF;

  RETURN v_request_id;
END;
$$;

ALTER FUNCTION private.dispatch_indexacao_servico_webhook(uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid) FROM anon;
REVOKE ALL ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid)
  TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.preparar_descricao_busca_servico_web()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'pg_catalog'
AS $$
DECLARE
  v_empresa_nome text;
  v_empresa_descricao text;
BEGIN
  IF TG_NAME IS DISTINCT FROM 'trg_cadastro_servicos_preparar_descricao_web'
     OR TG_WHEN IS DISTINCT FROM 'BEFORE'
     OR TG_TABLE_SCHEMA IS DISTINCT FROM 'private'
     OR TG_TABLE_NAME IS DISTINCT FROM 'cadastro_servicos' THEN
    RAISE EXCEPTION 'Acesso negado: funcao deve ser executada somente pelo trigger de servicos web.'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.origem_carga IS DISTINCT FROM 'web' THEN
    RETURN NEW;
  END IF;

  SELECT e.nome, e.descricao_negocio
    INTO v_empresa_nome, v_empresa_descricao
  FROM private.empresas e
  WHERE e.id = NEW.empresa_id;

  NEW.descricao_busca := concat_ws(E'\n',
    CASE WHEN NULLIF(btrim(v_empresa_nome), '') IS NOT NULL
      THEN 'Empresa: ' || btrim(v_empresa_nome) END,
    CASE WHEN NULLIF(btrim(NEW.nome), '') IS NOT NULL
      THEN 'Servico: ' || btrim(NEW.nome) END,
    CASE WHEN NULLIF(btrim(NEW.categoria_nome), '') IS NOT NULL
      THEN 'Categoria informada: ' || btrim(NEW.categoria_nome) END,
    CASE WHEN NULLIF(btrim(NEW.descricao), '') IS NOT NULL
      THEN 'Descricao: ' || btrim(NEW.descricao) END,
    CASE WHEN NULLIF(btrim(NEW.problemas_resolvidos), '') IS NOT NULL
      THEN 'Problemas atendidos: ' || btrim(NEW.problemas_resolvidos) END,
    CASE WHEN cardinality(COALESCE(NEW.especialidades, '{}'::text[])) > 0
      THEN 'Especialidades: ' || array_to_string(NEW.especialidades, ', ') END,
    CASE WHEN cardinality(COALESCE(NEW.categoria_aliases, '{}'::text[])) > 0
      THEN 'Termos informados: ' || array_to_string(NEW.categoria_aliases, ', ') END,
    CASE WHEN NULLIF(btrim(v_empresa_descricao), '') IS NOT NULL
      THEN 'Sobre a empresa: ' || btrim(v_empresa_descricao) END
  );

  RETURN NEW;
END;
$$;

ALTER FUNCTION private.preparar_descricao_busca_servico_web()
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION private.preparar_descricao_busca_servico_web() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.preparar_descricao_busca_servico_web() FROM anon;
REVOKE ALL ON FUNCTION private.preparar_descricao_busca_servico_web() FROM authenticated;
REVOKE ALL ON FUNCTION private.preparar_descricao_busca_servico_web() FROM service_role;

DROP TRIGGER IF EXISTS trg_cadastro_servicos_preparar_descricao_web
  ON private.cadastro_servicos;

CREATE TRIGGER trg_cadastro_servicos_preparar_descricao_web
BEFORE INSERT OR UPDATE OF
  empresa_id,
  nome,
  descricao,
  problemas_resolvidos,
  especialidades,
  categoria_nome,
  categoria_aliases,
  origem_carga
ON private.cadastro_servicos
FOR EACH ROW
EXECUTE FUNCTION private.preparar_descricao_busca_servico_web();

CREATE OR REPLACE FUNCTION private.notificar_n8n_indexar_servico_web()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'pg_catalog'
AS $$
BEGIN
  IF TG_NAME IS DISTINCT FROM 'trg_cadastro_servicos_notificar_indexacao_web'
     OR TG_WHEN IS DISTINCT FROM 'AFTER'
     OR TG_TABLE_SCHEMA IS DISTINCT FROM 'private'
     OR TG_TABLE_NAME IS DISTINCT FROM 'cadastro_servicos' THEN
    RAISE EXCEPTION 'Acesso negado: funcao deve ser executada somente pelo trigger de servicos web.'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.origem_carga IS DISTINCT FROM 'web'
     OR NEW.ativo IS NOT TRUE
     OR NEW.publicado IS NOT TRUE
     OR NEW.status_indexacao IS DISTINCT FROM 'pendente' THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM private.dispatch_indexacao_servico_webhook(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    -- O cadastro nao deve falhar por indisponibilidade temporaria do n8n.
    -- O servico continua pendente e sera recuperado pela rotina diaria.
    RAISE WARNING 'Indexacao imediata nao enfileirada para servico % (SQLSTATE %).', NEW.id, SQLSTATE;
  END;

  RETURN NEW;
END;
$$;

ALTER FUNCTION private.notificar_n8n_indexar_servico_web()
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION private.notificar_n8n_indexar_servico_web() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.notificar_n8n_indexar_servico_web() FROM anon;
REVOKE ALL ON FUNCTION private.notificar_n8n_indexar_servico_web() FROM authenticated;
REVOKE ALL ON FUNCTION private.notificar_n8n_indexar_servico_web() FROM service_role;

DROP TRIGGER IF EXISTS trg_cadastro_servicos_notificar_indexacao_web
  ON private.cadastro_servicos;

CREATE TRIGGER trg_cadastro_servicos_notificar_indexacao_web
AFTER INSERT OR UPDATE OF
  nome,
  descricao,
  problemas_resolvidos,
  categoria_nome,
  categoria_aliases,
  ativo,
  publicado,
  status_indexacao
ON private.cadastro_servicos
FOR EACH ROW
EXECUTE FUNCTION private.notificar_n8n_indexar_servico_web();

-- Recupera cadastros web criados antes desta automacao. A atualizacao monta a
-- descricao publica e o trigger AFTER agenda o processamento sem bloquear o cadastro.
UPDATE private.cadastro_servicos cs
   SET descricao = cs.descricao,
       status_indexacao = 'pendente',
       embedding = NULL,
       embedding_model = NULL,
       indexed_at = NULL,
       erro_indexacao = NULL,
       updated_at = clock_timestamp()
 WHERE cs.origem_carga = 'web'
   AND cs.ativo IS TRUE
   AND cs.publicado IS TRUE
   AND NULLIF(btrim(cs.descricao_busca), '') IS NULL;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;

COMMENT ON FUNCTION private.dispatch_indexacao_servico_webhook(uuid)
  IS 'Enfileira via pg_net o processamento imediato de um servico web publicado, enviando somente o UUID do servico.';

COMMENT ON TRIGGER trg_cadastro_servicos_notificar_indexacao_web ON private.cadastro_servicos
  IS 'Dispara o indexador n8n apos commit para servicos publicados pelo cadastro web; a rotina diaria permanece como contingencia.';

COMMENT ON TRIGGER trg_cadastro_servicos_preparar_descricao_web ON private.cadastro_servicos
  IS 'Monta o texto publico de busca dos servicos criados pelo cadastro web antes de enfileirar a geracao do embedding.';
