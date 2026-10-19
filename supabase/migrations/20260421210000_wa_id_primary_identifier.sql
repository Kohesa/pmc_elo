-- Consolidação: id_usuario_wa como identificador primário em todo o sistema.
-- Regras:
--   * Sessão SEMPRE iniciada e validada por id_usuario_wa
--   * id_usuario_wa é criptografado (enc) em todas as tabelas; hash para lookup
--   * Conversas usam wa_user_id enc+hash — sem telefone remetente/destinatario
--   * Telefone existe somente em cadastro e permanece opcional
--   * Dados legados serão deletados manualmente — sem backward compat

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

-- ===========================================================================
-- 1. private.cadastro — remover colunas plaintext da Fase1 (Fase2 já tem enc+hash)
-- ===========================================================================
DROP INDEX IF EXISTS private.idx_cadastro_whatsapp_user_id_hash;

ALTER TABLE private.cadastro
  DROP COLUMN IF EXISTS whatsapp_user_id,
  DROP COLUMN IF EXISTS whatsapp_user_id_hash,
  DROP COLUMN IF EXISTS whatsapp_alias;

-- ===========================================================================
-- 2. private.conversas — substituir colunas phone e wa_id plaintext por enc+hash
-- ===========================================================================

-- Dropar RLS policies que dependem das colunas legadas e recriar com wa_hash
DROP POLICY IF EXISTS conversas_insert ON private.conversas;
DROP POLICY IF EXISTS conversas_select ON private.conversas;
DROP POLICY IF EXISTS conversas_update ON private.conversas;

-- Dropar trigger e função legados (sincronizavam hash de telefone — substituídos por wa_id enc+hash na RPC)
DROP TRIGGER IF EXISTS trg_sync_conversas_lookup_hashes ON private.conversas;
DROP FUNCTION IF EXISTS private.sync_conversas_lookup_hashes();

ALTER TABLE private.conversas
  DROP COLUMN IF EXISTS remetente_enc,
  DROP COLUMN IF EXISTS destinatario_enc,
  DROP COLUMN IF EXISTS remetente_hash,
  DROP COLUMN IF EXISTS destinatario_hash,
  DROP COLUMN IF EXISTS remetente_wa_user_id,
  DROP COLUMN IF EXISTS destinatario_wa_user_id,
  ADD COLUMN IF NOT EXISTS remetente_wa_enc   text,
  ADD COLUMN IF NOT EXISTS remetente_wa_hash  text,
  ADD COLUMN IF NOT EXISTS destinatario_wa_enc  text,
  ADD COLUMN IF NOT EXISTS destinatario_wa_hash text;

CREATE INDEX IF NOT EXISTS idx_conversas_remetente_wa_hash
  ON private.conversas (remetente_wa_hash)
  WHERE remetente_wa_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_conversas_destinatario_wa_hash
  ON private.conversas (destinatario_wa_hash)
  WHERE destinatario_wa_hash IS NOT NULL;

-- ===========================================================================
-- 3. private.uso_tokens — adicionar enc+hash para wa_id, remover telefone_hash
-- ===========================================================================
DROP POLICY IF EXISTS uso_tokens_select ON private.uso_tokens;

ALTER TABLE private.uso_tokens
  ADD COLUMN IF NOT EXISTS wa_id_enc  text,
  ADD COLUMN IF NOT EXISTS wa_id_hash text,
  DROP COLUMN IF EXISTS telefone_hash;

CREATE INDEX IF NOT EXISTS idx_uso_tokens_wa_id_hash
  ON private.uso_tokens (wa_id_hash)
  WHERE wa_id_hash IS NOT NULL;

CREATE POLICY uso_tokens_select ON private.uso_tokens
  FOR SELECT
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND wa_id_hash = private.get_session_wa_id_hash()
  );


CREATE POLICY conversas_insert ON private.conversas
  FOR INSERT
  WITH CHECK (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash   = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  );

CREATE POLICY conversas_select ON private.conversas
  FOR SELECT
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  );

CREATE POLICY conversas_update ON private.conversas
  FOR UPDATE
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash   = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  )
  WITH CHECK (
    private.get_session_wa_id_hash() IS NOT NULL
    AND (
      remetente_wa_hash   = private.get_session_wa_id_hash()
      OR destinatario_wa_hash = private.get_session_wa_id_hash()
    )
  );

-- ===========================================================================
-- 4. private.activate_session_context — apenas id_usuario_wa; sem phone
--    Seta app.session_wa_id_hash E app.session_phone_hash (compat com RLS Fase1)
-- ===========================================================================
DROP FUNCTION IF EXISTS private.activate_session_context(text, text, text);
DROP FUNCTION IF EXISTS private.activate_session_context(text, text);

CREATE OR REPLACE FUNCTION private.activate_session_context(
  p_sessao_token  text,
  p_id_usuario_wa text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_payload   text;
  v_hash      text;
  v_exp_epoch bigint;
  v_id_hash   text;
BEGIN
  IF p_sessao_token IS NULL OR trim(p_sessao_token) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: sessao_token.'
      USING ERRCODE = '23502';
  END IF;

  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  BEGIN
    v_payload := private.decrypt_value(p_sessao_token);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END;

  v_hash := split_part(v_payload, '|', 1);

  BEGIN
    v_exp_epoch := split_part(v_payload, '|', 2)::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END;

  IF v_hash IS NULL OR trim(v_hash) = '' OR v_exp_epoch IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  IF v_exp_epoch <= extract(epoch FROM now())::bigint THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  v_id_hash := private.hash_value(p_id_usuario_wa);

  IF v_id_hash <> v_hash THEN
    RAISE EXCEPTION 'id_usuario_wa fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  -- Seta ambas as variáveis: session_wa_id_hash (primário) e session_phone_hash (compat RLS Fase1)
  PERFORM set_config('app.session_wa_id_hash', v_hash, false);
  PERFORM set_config('app.session_phone_hash',  v_hash, false);

  RETURN v_hash;
END;
$$;

REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM anon;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.activate_session_context(text, text) TO private_rpc_executor;


-- ===========================================================================
-- 5. public.rpc_set_contexto_sessao — p_id_usuario_wa obrigatório; sem phone
-- ===========================================================================
DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text, text, text, text);
DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text, text, text);

CREATE OR REPLACE FUNCTION public.rpc_set_contexto_sessao(
  p_token_s2s     text,
  p_id_usuario_wa text,
  p_sessao_token  text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_hash          text;
  v_exp_epoch     bigint := extract(epoch FROM (now() + interval '60 seconds'))::bigint;
  v_payload       text;
  v_sessao_token  text;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'set_contexto');

  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  v_hash := private.hash_value(p_id_usuario_wa);

  IF p_sessao_token IS NOT NULL AND trim(p_sessao_token) <> '' THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  v_payload      := v_hash || '|' || v_exp_epoch::text;
  v_sessao_token := private.encrypt_value(v_payload);

  PERFORM set_config('app.session_wa_id_hash', v_hash, false);
  PERFORM set_config('app.session_phone_hash',  v_hash, false);

  RETURN v_sessao_token;
END;
$$;

ALTER FUNCTION public.rpc_set_contexto_sessao(text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_contexto_sessao(text, text, text) TO service_role;


-- ===========================================================================
-- 6. public.rpc_inserir_cadastro — wa_id obrigatório para sessão; phone opcional
-- ===========================================================================
DROP FUNCTION IF EXISTS public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.rpc_inserir_cadastro(
  p_id_usuario_wa text,
  p_telefone      text DEFAULT NULL,
  p_nome          text DEFAULT NULL,
  p_tipo          text DEFAULT NULL,
  p_email         text DEFAULT NULL,
  p_instagram     text DEFAULT NULL,
  p_linkedin      text DEFAULT NULL,
  p_empresa       text DEFAULT NULL,
  p_cargo         text DEFAULT NULL,
  p_sessao_token  text DEFAULT NULL,
  p_alias         text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id      uuid;
  v_wa_hash text;
BEGIN
  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  v_wa_hash := private.hash_value(p_id_usuario_wa);

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF v_wa_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.cadastro (
    nome,
    tipo,
    telefone_enc,
    telefone_hash,
    email_enc,
    instagram_enc,
    linkedin_enc,
    empresa,
    cargo,
    alias_enc,
    id_usuario_wa_enc,
    id_usuario_wa_hash
  ) VALUES (
    p_nome,
    p_tipo,
    CASE WHEN p_telefone IS NOT NULL THEN private.encrypt_value(p_telefone) END,
    CASE WHEN p_telefone IS NOT NULL THEN private.hash_phone_number(p_telefone) END,
    CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     END,
    CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) END,
    CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  END,
    p_empresa,
    p_cargo,
    CASE WHEN p_alias IS NOT NULL THEN private.encrypt_value(p_alias) END,
    private.encrypt_value(p_id_usuario_wa),
    v_wa_hash
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Ja existe cadastro com este id_usuario_wa.'
      USING ERRCODE = '23505';
END;
$$;

ALTER FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) TO service_role;


-- ===========================================================================
-- 7. public.rpc_inserir_conversa — wa_ids enc+hash; sem phone remetente/destinatario
-- ===========================================================================
DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id             text,
  p_mensagem                text,
  p_remetente_wa_user_id    text,
  p_destinatario_wa_user_id text,
  p_cliente_id              uuid    DEFAULT NULL,
  p_sessao_token            text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id                uuid;
  v_session_hash      text;
  v_remetente_hash    text;
  v_destinatario_hash text;
  v_session_cadastro_id uuid;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_remetente_wa_user_id);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  v_session_cadastro_id := private.get_session_cadastro_id();

  IF p_mensagem_id IS NULL OR trim(p_mensagem_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_mensagem IS NULL OR trim(p_mensagem) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem.'
      USING ERRCODE = '23502';
  END IF;

  IF p_remetente_wa_user_id IS NULL OR trim(p_remetente_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: remetente_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_destinatario_wa_user_id IS NULL OR trim(p_destinatario_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: destinatario_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  v_session_hash      := private.get_session_phone_hash();
  v_remetente_hash    := private.hash_value(p_remetente_wa_user_id);
  v_destinatario_hash := private.hash_value(p_destinatario_wa_user_id);

  -- Remetente ou destinatario deve corresponder à sessão ativa
  IF v_remetente_hash <> v_session_hash AND v_destinatario_hash <> v_session_hash THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  IF p_cliente_id IS NOT NULL
     AND v_session_cadastro_id IS NOT NULL
     AND p_cliente_id <> v_session_cadastro_id THEN
    RAISE EXCEPTION 'cliente_id fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.conversas (
    mensagem_id,
    mensagem_enc,
    remetente_wa_enc,
    remetente_wa_hash,
    destinatario_wa_enc,
    destinatario_wa_hash,
    cliente_id
  ) VALUES (
    p_mensagem_id,
    private.encrypt_value(p_mensagem),
    private.encrypt_value(p_remetente_wa_user_id),
    v_remetente_hash,
    private.encrypt_value(p_destinatario_wa_user_id),
    v_destinatario_hash,
    COALESCE(p_cliente_id, v_session_cadastro_id)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) TO service_role;


-- ===========================================================================
-- 8. public.rpc_atualizar_conversa — atualizado para novas colunas enc+hash
-- ===========================================================================
DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION public.rpc_atualizar_conversa(
  p_mensagem_id             text,
  p_mensagem                text    DEFAULT NULL,
  p_cliente_id              uuid    DEFAULT NULL,
  p_status_mensagem         text    DEFAULT NULL,
  p_remetente_wa_user_id    text    DEFAULT NULL,
  p_destinatario_wa_user_id text    DEFAULT NULL,
  p_sessao_token            text    DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_session_cadastro_id uuid;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_remetente_wa_user_id);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  v_session_cadastro_id := private.get_session_cadastro_id();

  IF p_mensagem_id IS NULL OR trim(p_mensagem_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_cliente_id IS NOT NULL
     AND v_session_cadastro_id IS NOT NULL
     AND p_cliente_id <> v_session_cadastro_id THEN
    RAISE EXCEPTION 'cliente_id fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE private.conversas SET
    mensagem_enc         = CASE WHEN NULLIF(trim(p_mensagem), '') IS NOT NULL
                                THEN private.encrypt_value(p_mensagem)
                                ELSE mensagem_enc END,
    status_mensagem      = COALESCE(p_status_mensagem, status_mensagem),
    remetente_wa_enc     = CASE WHEN p_remetente_wa_user_id IS NOT NULL AND remetente_wa_enc IS NULL
                                THEN private.encrypt_value(p_remetente_wa_user_id)
                                ELSE remetente_wa_enc END,
    remetente_wa_hash    = CASE WHEN p_remetente_wa_user_id IS NOT NULL AND remetente_wa_hash IS NULL
                                THEN private.hash_value(p_remetente_wa_user_id)
                                ELSE remetente_wa_hash END,
    destinatario_wa_enc  = CASE WHEN p_destinatario_wa_user_id IS NOT NULL AND destinatario_wa_enc IS NULL
                                THEN private.encrypt_value(p_destinatario_wa_user_id)
                                ELSE destinatario_wa_enc END,
    destinatario_wa_hash = CASE WHEN p_destinatario_wa_user_id IS NOT NULL AND destinatario_wa_hash IS NULL
                                THEN private.hash_value(p_destinatario_wa_user_id)
                                ELSE destinatario_wa_hash END
  WHERE mensagem_id = p_mensagem_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: mensagem_id %', p_mensagem_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) TO service_role;


-- ===========================================================================
-- 9. public.rpc_selecionar_conversas_por_wa_id — substitui rpc_selecionar_conversas_por_numero
-- ===========================================================================
DROP FUNCTION IF EXISTS public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text);

CREATE OR REPLACE FUNCTION public.rpc_selecionar_conversas_por_wa_id(
  p_id_usuario_wa text,
  p_pagina        integer DEFAULT 1,
  p_limite        integer DEFAULT 100,
  p_sessao_token  text    DEFAULT NULL,
  p_mensagem_id   text    DEFAULT NULL
) RETURNS TABLE(
  id                   uuid,
  mensagem_id          text,
  mensagem             text,
  remetente_wa_user_id text,
  destinatario_wa_user_id text,
  horario_mensagem     timestamptz,
  horario_mensagem_api timestamptz,
  status_mensagem      text,
  cliente_id           uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text    := private.hash_value(p_id_usuario_wa);
  v_pagina  integer := COALESCE(p_pagina, 1);
  v_limite  integer := LEAST(COALESCE(p_limite, 100), 300);
  v_offset  integer;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  IF v_wa_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'id_usuario_wa fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  IF v_pagina < 1 THEN
    RAISE EXCEPTION 'Parametro invalido: pagina deve ser maior que zero.'
      USING ERRCODE = '22023';
  END IF;

  IF v_limite < 1 THEN
    RAISE EXCEPTION 'Parametro invalido: limite deve ser maior que zero.'
      USING ERRCODE = '22023';
  END IF;

  IF p_mensagem_id IS NOT NULL THEN
    RETURN QUERY
    SELECT
      c.id,
      c.mensagem_id,
      private.decrypt_value(c.mensagem_enc),
      private.decrypt_value(c.remetente_wa_enc),
      private.decrypt_value(c.destinatario_wa_enc),
      c.horario_mensagem,
      c.horario_mensagem_api,
      c.status_mensagem,
      c.cliente_id
    FROM private.conversas c
    WHERE c.mensagem_id = p_mensagem_id
      AND (c.remetente_wa_hash = v_wa_hash OR c.destinatario_wa_hash = v_wa_hash)
    ORDER BY COALESCE(c.horario_mensagem_api, c.horario_mensagem) DESC, c.id DESC;

    RETURN;
  END IF;

  v_offset := (v_pagina - 1) * v_limite;

  RETURN QUERY
  WITH matching_rows AS (
    SELECT c.id, COALESCE(c.horario_mensagem_api, c.horario_mensagem) AS horario_ordenacao
    FROM private.conversas c
    WHERE c.remetente_wa_hash = v_wa_hash

    UNION

    SELECT c.id, COALESCE(c.horario_mensagem_api, c.horario_mensagem) AS horario_ordenacao
    FROM private.conversas c
    WHERE c.destinatario_wa_hash = v_wa_hash
  ),
  paged_ids AS (
    SELECT mr.id
    FROM matching_rows mr
    ORDER BY mr.horario_ordenacao DESC, mr.id DESC
    LIMIT v_limite
    OFFSET v_offset
  )
  SELECT
    c.id,
    c.mensagem_id,
    private.decrypt_value(c.mensagem_enc),
    private.decrypt_value(c.remetente_wa_enc),
    private.decrypt_value(c.destinatario_wa_enc),
    c.horario_mensagem,
    c.horario_mensagem_api,
    c.status_mensagem,
    c.cliente_id
  FROM private.conversas c
  INNER JOIN paged_ids p ON p.id = c.id
  ORDER BY COALESCE(c.horario_mensagem_api, c.horario_mensagem) DESC, c.id DESC;
END;
$$;

ALTER FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_conversas_por_wa_id(text, integer, integer, text, text) TO service_role;


-- ===========================================================================
-- 10. public.rpc_selecionar_cadastro_por_wa_id — busca cadastro pelo wa_id da sessão
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_wa_id(
  p_id_usuario_wa text,
  p_sessao_token  text DEFAULT NULL
) RETURNS TABLE(
  id            uuid,
  nome          text,
  tipo          text,
  telefone      text,
  email         text,
  instagram     text,
  linkedin      text,
  empresa       text,
  cargo         text,
  alias         text,
  id_usuario_wa text,
  status        text,
  created_at    timestamptz,
  updated_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_wa_hash text;
BEGIN
  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  v_wa_hash := private.hash_value(p_id_usuario_wa);

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  IF private.get_session_wa_id_hash() IS NULL THEN
    RAISE EXCEPTION 'Sessao nao iniciada.'
      USING ERRCODE = '42501';
  END IF;

  IF v_wa_hash <> private.get_session_wa_id_hash() THEN
    RAISE EXCEPTION 'id_usuario_wa fora do contexto da sessao.'
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
    private.decrypt_value(c.alias_enc),
    private.decrypt_value(c.id_usuario_wa_enc),
    c.status,
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.id_usuario_wa_hash = v_wa_hash;
END;
$$;

ALTER FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_wa_id(text, text) TO service_role;


-- ===========================================================================

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
