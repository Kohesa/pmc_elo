-- Fase 1 - RAG contextual: helpers, RPCs e limpeza programada.
-- Depende da migration 20260520120000_phase1_contextual_rag.sql,
-- que cria as tabelas privadas, indices, triggers, RLS e grants.
-- Mantem acesso externo somente por RPC, com S2S + sessao WhatsApp.
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- Helper privado para ativar uma sessao WhatsApp dentro de RPCs S2S.
-- A validacao real do token continua centralizada em private.activate_session_context.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.validar_sessao_wa_s2s(
  p_wa_user_id text,
  p_sessao_token text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
BEGIN
  v_wa_hash := private.activate_session_context(p_sessao_token, p_wa_user_id);
  PERFORM set_config('app.session_s2s_validated', 'true', true);

  RETURN v_wa_hash;
END;
$$;

ALTER FUNCTION private.validar_sessao_wa_s2s(text, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION private.validar_sessao_wa_s2s(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.validar_sessao_wa_s2s(text, text) FROM anon;
REVOKE ALL ON FUNCTION private.validar_sessao_wa_s2s(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.validar_sessao_wa_s2s(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.validar_sessao_wa_s2s(text, text)
  TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- Todas as conversas da Elo consultam a mesma base padrão. O cadastro é
-- retornado apenas para associar memória e consumo de tokens à conversa.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.resolver_acesso_contexto_ia_s2s(
  p_wa_hash text
) RETURNS TABLE (
  cadastro_id uuid,
  acesso_base_publica boolean,
  tipo_acesso text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  IF p_wa_hash IS NULL OR btrim(p_wa_hash) = '' THEN
    RAISE EXCEPTION 'Sessao WhatsApp invalida.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    c.id AS cadastro_id,
    true AS acesso_base_publica,
    'base_padrao'::text AS tipo_acesso
  FROM private.cadastro c
  WHERE c.id_usuario_wa_hash = p_wa_hash
  ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC, c.id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    NULL::uuid AS cadastro_id,
    true AS acesso_base_publica,
    'base_padrao'::text AS tipo_acesso;
END;
$$;

ALTER FUNCTION private.resolver_acesso_contexto_ia_s2s(text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION private.resolver_acesso_contexto_ia_s2s(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.resolver_acesso_contexto_ia_s2s(text) FROM anon;
REVOKE ALL ON FUNCTION private.resolver_acesso_contexto_ia_s2s(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.resolver_acesso_contexto_ia_s2s(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.resolver_acesso_contexto_ia_s2s(text)
  TO private_rpc_executor;

-- ---------------------------------------------------------------------------
-- RPCs para salvar o indice semantico do documento.
-- O n8n gera o resumo e o embedding; o Supabase valida tenant, criptografa
-- campos textuais e grava o indice.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.limpar_conversas_contexto_ia_expiradas(
  p_limite integer DEFAULT 1000
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
SET lock_timeout TO '2s'
SET statement_timeout TO '15s'
AS $$
DECLARE
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 1000), 1), 5000);
  v_rows integer := 0;
BEGIN
  WITH alvo AS (
    SELECT cci.id
    FROM private.conversas_contexto_ia cci
    WHERE cci.expires_at <= now()
    ORDER BY cci.expires_at, cci.id
    LIMIT v_limite
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM private.conversas_contexto_ia cci
  USING alvo
  WHERE cci.id = alvo.id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows;
END;
$$;

ALTER FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer) FROM anon;
REVOKE ALL ON FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer) FROM authenticated;
REVOKE ALL ON FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer) FROM service_role;
REVOKE ALL ON FUNCTION private.limpar_conversas_contexto_ia_expiradas(integer) FROM private_rpc_executor;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.unschedule('elo_limpar_contexto_ia_expirado')
WHERE EXISTS (
  SELECT 1
  FROM cron.job
  WHERE jobname = 'elo_limpar_contexto_ia_expirado'
);

SELECT cron.schedule(
  'elo_limpar_contexto_ia_expirado',
  '*/5 * * * *',
  $cron$SELECT private.limpar_conversas_contexto_ia_expiradas(1000);$cron$
);

-- ---------------------------------------------------------------------------
-- RPCs para memoria ativa curta da conversa.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_obter_contexto_ia_s2s(
  p_wa_user_id text,
  p_sessao_token text,
  p_token_s2s text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
  v_cadastro_id uuid;
  v_acesso_base_publica boolean := true;
  v_tipo_acesso text := 'sem_cadastro';
  v_result jsonb;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  v_wa_hash := private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  SELECT
    r.cadastro_id,
    r.acesso_base_publica,
    r.tipo_acesso
    INTO v_cadastro_id, v_acesso_base_publica, v_tipo_acesso
  FROM private.resolver_acesso_contexto_ia_s2s(v_wa_hash) r;

  IF v_acesso_base_publica IS TRUE THEN
    PERFORM set_config('app.session_base_conhecimento_publica_validated', 'true', true);
  END IF;

  IF v_cadastro_id IS NULL THEN
    RETURN jsonb_build_object(
      'existe', false,
      'motivo', 'cadastro_nao_encontrado',
      'acesso_base_publica', v_acesso_base_publica,
      'tipo_acesso', v_tipo_acesso
    );
  END IF;

  SELECT jsonb_build_object(
    'existe', true,
    'cadastro_id', cci.cadastro_id,
    'acesso_base_publica', v_acesso_base_publica,
    'tipo_acesso', v_tipo_acesso,
    'documento_ativo_id', cci.documento_ativo_id,
    'documento_ativo_titulo',
      CASE
        WHEN cci.documento_ativo_titulo_enc IS NULL THEN NULL
        ELSE private.decrypt_value(cci.documento_ativo_titulo_enc)
      END,
    'assunto_ativo',
      CASE
        WHEN cci.assunto_ativo_enc IS NULL THEN NULL
        ELSE private.decrypt_value(cci.assunto_ativo_enc)
      END,
    'entidades_ativas',
      CASE
        WHEN cci.entidades_ativas_json_enc IS NULL THEN '{}'::jsonb
        ELSE private.decrypt_value(cci.entidades_ativas_json_enc)::jsonb
      END,
    'ultima_pergunta',
      CASE
        WHEN cci.ultima_pergunta_enc IS NULL THEN NULL
        ELSE private.decrypt_value(cci.ultima_pergunta_enc)
      END,
    'ultima_resposta',
      CASE
        WHEN cci.ultima_resposta_enc IS NULL THEN NULL
        ELSE private.decrypt_value(cci.ultima_resposta_enc)
      END,
    'score_documento_ativo', cci.score_documento_ativo,
    'expires_at', cci.expires_at
  )
  INTO v_result
  FROM private.conversas_contexto_ia cci
  WHERE cci.cadastro_id = v_cadastro_id
    AND cci.whatsapp_user_id_hash = v_wa_hash
    AND cci.expires_at > now()
  LIMIT 1;

  RETURN COALESCE(
    v_result,
    jsonb_build_object(
      'existe', false,
      'cadastro_id', v_cadastro_id,
      'acesso_base_publica', v_acesso_base_publica,
      'tipo_acesso', v_tipo_acesso
    )
  );
END;
$$;

ALTER FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_obter_contexto_ia_s2s(text, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_salvar_contexto_ia_s2s(
  p_wa_user_id text,
  p_sessao_token text,
  p_documento_ativo_id uuid,
  p_documento_ativo_titulo text,
  p_assunto_ativo text,
  p_entidades_ativas_json jsonb,
  p_ultima_pergunta text,
  p_ultima_resposta text,
  p_score_documento_ativo double precision,
  p_ttl_minutos integer,
  p_token_s2s text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
  v_cadastro_id uuid;
  v_acesso_base_publica boolean := true;
  v_tipo_acesso text := 'sem_cadastro';
  v_ttl integer := COALESCE(p_ttl_minutos, 60);
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  v_wa_hash := private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  IF v_ttl < 5 OR v_ttl > 1440 THEN
    RAISE EXCEPTION 'Parametro invalido: ttl_minutos deve estar entre 5 e 1440.'
      USING ERRCODE = '22023';
  END IF;

  IF p_score_documento_ativo IS NOT NULL
     AND (p_score_documento_ativo < -1 OR p_score_documento_ativo > 1) THEN
    RAISE EXCEPTION 'Parametro invalido: score_documento_ativo deve estar entre -1 e 1.'
      USING ERRCODE = '22023';
  END IF;

  SELECT
    r.cadastro_id,
    r.acesso_base_publica,
    r.tipo_acesso
    INTO v_cadastro_id, v_acesso_base_publica, v_tipo_acesso
  FROM private.resolver_acesso_contexto_ia_s2s(v_wa_hash) r;

  IF v_acesso_base_publica IS TRUE THEN
    PERFORM set_config('app.session_base_conhecimento_publica_validated', 'true', true);
  END IF;

  IF v_cadastro_id IS NULL THEN
    RETURN false;
  END IF;

  IF p_documento_ativo_id IS NOT NULL THEN
    PERFORM 1
    FROM private.base_conhecimento bc
    WHERE bc.id = p_documento_ativo_id
      AND bc.cadastro_id IS NULL
      AND bc.status_processamento = 'processado'
      AND bc.status_indexacao = 'indexado';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Documento ativo nao pertence ao escopo da sessao ou nao esta indexado: id %, tipo_acesso %',
        p_documento_ativo_id,
        v_tipo_acesso
        USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO private.conversas_contexto_ia (
    cadastro_id,
    whatsapp_user_id_hash,
    documento_ativo_id,
    documento_ativo_titulo_enc,
    assunto_ativo_enc,
    entidades_ativas_json_enc,
    ultima_pergunta_enc,
    ultima_resposta_enc,
    score_documento_ativo,
    expires_at
  ) VALUES (
    v_cadastro_id,
    v_wa_hash,
    p_documento_ativo_id,
    CASE
      WHEN p_documento_ativo_titulo IS NULL OR btrim(p_documento_ativo_titulo) = '' THEN NULL
      ELSE private.encrypt_value(p_documento_ativo_titulo)
    END,
    CASE
      WHEN p_assunto_ativo IS NULL OR btrim(p_assunto_ativo) = '' THEN NULL
      ELSE private.encrypt_value(p_assunto_ativo)
    END,
    private.encrypt_value(COALESCE(p_entidades_ativas_json, '{}'::jsonb)::text),
    CASE
      WHEN p_ultima_pergunta IS NULL OR btrim(p_ultima_pergunta) = '' THEN NULL
      ELSE private.encrypt_value(p_ultima_pergunta)
    END,
    CASE
      WHEN p_ultima_resposta IS NULL OR btrim(p_ultima_resposta) = '' THEN NULL
      ELSE private.encrypt_value(p_ultima_resposta)
    END,
    p_score_documento_ativo,
    now() + make_interval(mins => v_ttl)
  )
  ON CONFLICT (cadastro_id, whatsapp_user_id_hash) DO UPDATE
  SET
    documento_ativo_id = EXCLUDED.documento_ativo_id,
    documento_ativo_titulo_enc = EXCLUDED.documento_ativo_titulo_enc,
    assunto_ativo_enc = EXCLUDED.assunto_ativo_enc,
    entidades_ativas_json_enc = EXCLUDED.entidades_ativas_json_enc,
    ultima_pergunta_enc = EXCLUDED.ultima_pergunta_enc,
    ultima_resposta_enc = EXCLUDED.ultima_resposta_enc,
    score_documento_ativo = EXCLUDED.score_documento_ativo,
    expires_at = EXCLUDED.expires_at;

  RETURN true;
END;
$$;

ALTER FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_salvar_contexto_ia_s2s(
  text, text, uuid, text, text, jsonb, text, text, double precision, integer, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_limpar_contexto_ia_s2s(
  p_wa_user_id text,
  p_sessao_token text,
  p_token_s2s text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
  v_cadastro_id uuid;
  v_rows integer := 0;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'buscar_contexto_ia');
  v_wa_hash := private.validar_sessao_wa_s2s(p_wa_user_id, p_sessao_token);

  SELECT r.cadastro_id
    INTO v_cadastro_id
  FROM private.resolver_acesso_contexto_ia_s2s(v_wa_hash) r;

  PERFORM set_config('app.session_base_conhecimento_publica_validated', 'true', true);

  IF v_cadastro_id IS NULL THEN
    RETURN false;
  END IF;

  DELETE FROM private.conversas_contexto_ia cci
  WHERE cci.cadastro_id = v_cadastro_id
    AND cci.whatsapp_user_id_hash = v_wa_hash;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END;
$$;

ALTER FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text)
  OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_limpar_contexto_ia_s2s(text, text, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Atualizacao da RPC existente de busca.
-- A chamada continua sendo pela mesma RPC, agora com parametros opcionais novos:
-- - p_documento_ativo_id / p_usar_documento_ativo: usa memoria ativa como pista;
-- - p_top_documentos: escolhe documentos antes de escolher chunks;
-- - p_chunks_por_documento: evita um documento parecido dominar todo o contexto;
-- - p_vizinhos: inclui chunk_index -1/+1 para devolver continuidade.
-- ---------------------------------------------------------------------------

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
