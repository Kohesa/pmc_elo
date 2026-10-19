-- Identidade unificada para os canais do Chatwoot. Widget e WhatsApp usam o
-- mesmo contrato e diferem apenas pelo identificador entregue pelo Chatwoot.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.get_session_cadastro_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT c.id
  FROM private.cadastro c
  WHERE c.id_usuario_wa_hash = private.get_session_wa_id_hash()
  ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC, c.id DESC
  LIMIT 1;
$$;

ALTER FUNCTION private.get_session_cadastro_id() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.get_session_cadastro_id() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.get_session_cadastro_id() TO private_rpc_executor;

DROP POLICY IF EXISTS conversas_elo_session_select ON private.conversas;
CREATE POLICY conversas_elo_session_select ON private.conversas
  FOR SELECT TO private_rpc_executor
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  );

DROP POLICY IF EXISTS conversas_elo_session_update ON private.conversas;
CREATE POLICY conversas_elo_session_update ON private.conversas
  FOR UPDATE TO private_rpc_executor
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  )
  WITH CHECK (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  );

DROP POLICY IF EXISTS uso_tokens_elo_session_select ON private.uso_tokens;
CREATE POLICY uso_tokens_elo_session_select ON private.uso_tokens
  FOR SELECT TO private_rpc_executor
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND wa_id_hash = private.get_session_wa_id_hash()
  );

DROP POLICY IF EXISTS categorias_elo_default_access ON private.categorias;
CREATE POLICY categorias_elo_default_access ON private.categorias
  TO private_rpc_executor
  USING (cadastro_id IS NULL)
  WITH CHECK (cadastro_id IS NULL);

DROP POLICY IF EXISTS base_conhecimento_elo_default_access ON private.base_conhecimento;
CREATE POLICY base_conhecimento_elo_default_access ON private.base_conhecimento
  TO private_rpc_executor
  USING (cadastro_id IS NULL)
  WITH CHECK (cadastro_id IS NULL);

DROP POLICY IF EXISTS base_conhecimento_chunks_elo_default_access ON private.base_conhecimento_chunks;
CREATE POLICY base_conhecimento_chunks_elo_default_access ON private.base_conhecimento_chunks
  TO private_rpc_executor
  USING (cadastro_id IS NULL)
  WITH CHECK (cadastro_id IS NULL);

DROP POLICY IF EXISTS base_conhecimento_documentos_indice_elo_default_access
  ON private.base_conhecimento_documentos_indice;
CREATE POLICY base_conhecimento_documentos_indice_elo_default_access
  ON private.base_conhecimento_documentos_indice
  TO private_rpc_executor
  USING (cadastro_id IS NULL)
  WITH CHECK (cadastro_id IS NULL);

CREATE UNIQUE INDEX IF NOT EXISTS ux_cadastro_id_usuario_wa_hash
  ON private.cadastro (id_usuario_wa_hash)
  WHERE id_usuario_wa_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cadastro_telefone_hash_lookup
  ON private.cadastro (telefone_hash)
  WHERE telefone_hash IS NOT NULL;

-- O identificador normalizado do Chatwoot e a identidade da sessao. O telefone
-- continua sendo um dado opcional do cadastro e nao concede acesso a registros.
DROP POLICY IF EXISTS cadastro_select ON private.cadastro;
CREATE POLICY cadastro_select ON private.cadastro
  FOR SELECT TO private_rpc_executor
  USING (
    (
      public.request_jwt_sub() IS NOT NULL
      AND auth_user_id = public.request_jwt_sub()
    )
    OR (
      private.get_session_wa_id_hash() IS NOT NULL
      AND id_usuario_wa_hash = private.get_session_wa_id_hash()
    )
  );

DROP POLICY IF EXISTS cadastro_insert ON private.cadastro;
CREATE POLICY cadastro_insert ON private.cadastro
  FOR INSERT TO private_rpc_executor
  WITH CHECK (
    private.get_session_wa_id_hash() IS NOT NULL
    AND id_usuario_wa_hash = private.get_session_wa_id_hash()
  );

DROP POLICY IF EXISTS cadastro_update ON private.cadastro;
CREATE POLICY cadastro_update ON private.cadastro
  FOR UPDATE TO private_rpc_executor
  USING (
    (
      public.request_jwt_sub() IS NOT NULL
      AND auth_user_id = public.request_jwt_sub()
    )
    OR (
      private.get_session_wa_id_hash() IS NOT NULL
      AND id_usuario_wa_hash = private.get_session_wa_id_hash()
    )
  )
  WITH CHECK (
    (
      public.request_jwt_sub() IS NOT NULL
      AND auth_user_id IS NOT DISTINCT FROM public.request_jwt_sub()
    )
    OR (
      private.get_session_wa_id_hash() IS NOT NULL
      AND id_usuario_wa_hash = private.get_session_wa_id_hash()
    )
  );

DROP FUNCTION IF EXISTS public.rpc_identificar_numero(text, text, text);
DROP FUNCTION IF EXISTS public.rpc_identificar_numero(text, text);

CREATE OR REPLACE FUNCTION public.rpc_identificar_numero(
  p_id_usuario_wa text,
  p_token_s2s text
) RETURNS TABLE (
  tipo_acesso text,
  cadastro_id uuid,
  status_cadastro text,
  sessao_token text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
  v_cadastro_id uuid;
  v_status text;
  v_sessao_token text;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'identificar');

  IF p_id_usuario_wa IS NULL OR btrim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  v_wa_hash := private.hash_value(p_id_usuario_wa);

  -- Mesmo padrao da Koris: estabelecer o contexto antes de consultar tabelas
  -- protegidas por RLS. O telefone e apenas um dado opcional do cadastro.
  PERFORM set_config('app.session_wa_id_hash', v_wa_hash, false);

  SELECT c.id, c.status
  INTO v_cadastro_id, v_status
  FROM private.cadastro c
  WHERE c.id_usuario_wa_hash = v_wa_hash
  ORDER BY c.created_at DESC
  LIMIT 1;

  v_sessao_token := private.encrypt_value(
    v_wa_hash || '|' || extract(epoch FROM now() + interval '5 minutes')::bigint::text
  );

  IF v_cadastro_id IS NULL THEN
    RETURN QUERY SELECT 'novo'::text, NULL::uuid, 'aprovado'::text, v_sessao_token;
    RETURN;
  END IF;

  IF v_status = 'bloqueado' THEN
    RETURN QUERY SELECT 'bloqueado'::text, v_cadastro_id, v_status, v_sessao_token;
  ELSE
    RETURN QUERY SELECT 'aprovado'::text, v_cadastro_id, 'aprovado'::text, v_sessao_token;
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_identificar_numero(text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_identificar_numero(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_identificar_numero(text, text) TO service_role;

DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_wa_id(text, text, text);
DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_wa_id(text, text);

CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_wa_id(
  p_id_usuario_wa text,
  p_sessao_token text
) RETURNS TABLE (
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
BEGIN
  v_wa_hash := private.activate_session_context(p_sessao_token);
  IF private.hash_value(p_id_usuario_wa) IS DISTINCT FROM v_wa_hash THEN
    RAISE EXCEPTION 'Sessao nao corresponde ao identificador informado.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    c.id,
    c.nome,
    c.tipo,
    private.decrypt_value(c.telefone_enc),
    private.decrypt_value(c.email_enc),
    private.decrypt_value(c.instagram_enc),
    private.decrypt_value(c.linkedin_enc),
    c.empresa,
    c.cargo,
    c.status,
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.id_usuario_wa_hash = v_wa_hash
  ORDER BY c.created_at DESC
  LIMIT 1;
END;
$$;

ALTER FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) TO service_role;

DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_id(uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_id(
  p_id uuid,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE (
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  RETURN QUERY
  SELECT
    c.id,
    c.nome,
    c.tipo,
    private.decrypt_value(c.telefone_enc),
    private.decrypt_value(c.email_enc),
    private.decrypt_value(c.instagram_enc),
    private.decrypt_value(c.linkedin_enc),
    c.empresa,
    c.cargo,
    c.status,
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.id = p_id
    AND c.id_usuario_wa_hash = private.get_session_wa_id_hash();
END;
$$;

ALTER FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) TO service_role;

-- No widget, o cadastro pode existir antes de o usuario informar um telefone.
-- Permite preencher o telefone uma unica vez e conserva a protecao original
-- contra substituicao posterior do numero.
CREATE OR REPLACE FUNCTION private.protect_telefone()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
BEGIN
  IF OLD.telefone_enc IS NOT NULL OR OLD.telefone_hash IS NOT NULL THEN
    IF NEW.telefone_enc IS DISTINCT FROM OLD.telefone_enc
       OR NEW.telefone_hash IS DISTINCT FROM OLD.telefone_hash THEN
      RAISE EXCEPTION 'O telefone nao pode ser alterado apos o cadastro.'
        USING ERRCODE = '23507';
    END IF;
  ELSIF (NEW.telefone_enc IS NULL) IS DISTINCT FROM (NEW.telefone_hash IS NULL) THEN
    RAISE EXCEPTION 'Telefone criptografado e hash devem ser preenchidos juntos.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION private.protect_telefone() OWNER TO postgres;

DROP FUNCTION IF EXISTS public.rpc_atualizar_cadastro(
  uuid, text, text, text, text, text, text, text, text, text, text
);

CREATE OR REPLACE FUNCTION public.rpc_atualizar_cadastro(
  p_id uuid,
  p_nome text DEFAULT NULL,
  p_tipo text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL,
  p_empresa text DEFAULT NULL,
  p_cargo text DEFAULT NULL,
  p_sessao_token text DEFAULT NULL,
  p_alias text DEFAULT NULL,
  p_id_usuario_wa text DEFAULT NULL,
  p_telefone text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_session_wa_hash text;
  v_telefone text;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  v_session_wa_hash := private.get_session_wa_id_hash();
  IF v_session_wa_hash IS NULL THEN
    RAISE EXCEPTION 'Sessao Chatwoot nao iniciada.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_id_usuario_wa IS NOT NULL
     AND private.hash_value(p_id_usuario_wa) IS DISTINCT FROM v_session_wa_hash THEN
    RAISE EXCEPTION 'Sessao nao corresponde ao identificador do Chatwoot informado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_tipo IS NOT NULL
     AND NULLIF(btrim(p_tipo), '') IS NOT NULL
     AND btrim(p_tipo) <> 'Pessoa' THEN
    RAISE EXCEPTION 'Parametro invalido: tipo deve ser Pessoa.'
      USING ERRCODE = '22023';
  END IF;

  v_telefone := NULLIF(btrim(p_telefone), '');

  UPDATE private.cadastro SET
    nome          = COALESCE(p_nome, nome),
    tipo          = 'Pessoa',
    telefone_enc  = CASE
      WHEN v_telefone IS NOT NULL AND telefone_enc IS NULL
        THEN private.encrypt_value(v_telefone)
      ELSE telefone_enc
    END,
    telefone_hash = CASE
      WHEN v_telefone IS NOT NULL AND telefone_hash IS NULL
        THEN private.hash_phone_number(v_telefone)
      ELSE telefone_hash
    END,
    email_enc     = CASE WHEN p_email IS NOT NULL THEN private.encrypt_value(p_email) ELSE email_enc END,
    instagram_enc = CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) ELSE instagram_enc END,
    linkedin_enc  = CASE WHEN p_linkedin IS NOT NULL THEN private.encrypt_value(p_linkedin) ELSE linkedin_enc END,
    empresa       = COALESCE(p_empresa, empresa),
    cargo         = COALESCE(p_cargo, cargo),
    alias_enc     = CASE WHEN p_alias IS NOT NULL AND alias_enc IS NULL THEN private.encrypt_value(p_alias) ELSE alias_enc END,
    updated_at    = now()
  WHERE id = p_id
    AND id_usuario_wa_hash = v_session_wa_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_atualizar_cadastro(
  uuid, text, text, text, text, text, text, text, text, text, text, text
) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(
  uuid, text, text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_cadastro(
  uuid, text, text, text, text, text, text, text, text, text, text, text
) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
