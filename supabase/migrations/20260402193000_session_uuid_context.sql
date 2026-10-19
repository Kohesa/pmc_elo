CREATE OR REPLACE FUNCTION private.activate_session_context(
  p_sessao_token text,
  p_telefone text DEFAULT NULL
) RETURNS text
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'off'
AS $$
DECLARE
  v_payload text;
  v_hash text;
  v_exp_epoch bigint;
  v_phone_hash text := private.hash_phone_number(p_telefone);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_sessao_token IS NULL OR trim(p_sessao_token) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: sessao_token.'
      USING ERRCODE = '23502';
  END IF;

  BEGIN
    v_payload := private.decrypt_value(p_sessao_token);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION 'Sessao invalida ou expirada.'
        USING ERRCODE = '42501';
  END;

  v_hash := split_part(v_payload, '|', 1);

  BEGIN
    v_exp_epoch := split_part(v_payload, '|', 2)::bigint;
  EXCEPTION
    WHEN OTHERS THEN
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

  IF v_phone_hash IS NOT NULL AND v_phone_hash <> v_hash THEN
    RAISE EXCEPTION 'Telefone fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.session_phone_hash', v_hash, false);

  RETURN v_hash;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text);
CREATE OR REPLACE FUNCTION public.rpc_set_contexto_sessao(
  p_telefone text,
  p_sessao_token text DEFAULT NULL
) RETURNS text
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'off'
AS $$
DECLARE
  v_hash text := private.hash_phone_number(p_telefone);
  v_exp_epoch bigint := extract(epoch FROM (now() + interval '10 seconds'))::bigint;
  v_payload text;
  v_sessao_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  IF p_sessao_token IS NOT NULL AND trim(p_sessao_token) <> '' THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone);
  END IF;

  v_payload := v_hash || '|' || v_exp_epoch::text;
  v_sessao_token := private.encrypt_value(v_payload);

  PERFORM set_config('app.session_phone_hash', v_hash, false);

  RETURN v_sessao_token;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_inserir_cadastro(
  p_telefone text,
  p_nome text DEFAULT NULL,
  p_tipo text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL,
  p_empresa text DEFAULT NULL,
  p_cargo text DEFAULT NULL,
  p_sessao_token text DEFAULT NULL
) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_id uuid;
  v_hash text := private.hash_phone_number(p_telefone);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  IF v_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'Telefone fora do contexto da sessao.'
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
    cargo
  ) VALUES (
    p_nome,
    p_tipo,
    private.encrypt_value(p_telefone),
    v_hash,
    CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     END,
    CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) END,
    CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  END,
    p_empresa,
    p_cargo
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Ja existe cadastro com este telefone.'
      USING ERRCODE = '23505';
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid);
CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id text,
  p_remetente text,
  p_destinatario text,
  p_mensagem text,
  p_cliente_id uuid,
  p_sessao_token text DEFAULT NULL
) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_id uuid;
  v_session_cadastro_id uuid := private.get_session_cadastro_id();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF p_mensagem_id IS NULL OR trim(p_mensagem_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_remetente IS NULL OR trim(p_remetente) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: remetente.'
      USING ERRCODE = '23502';
  END IF;

  IF p_destinatario IS NULL OR trim(p_destinatario) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: destinatario.'
      USING ERRCODE = '23502';
  END IF;

  IF p_mensagem IS NULL OR trim(p_mensagem) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: mensagem.'
      USING ERRCODE = '23502';
  END IF;

  IF p_cliente_id IS NOT NULL
     AND v_session_cadastro_id IS NOT NULL
     AND p_cliente_id <> v_session_cadastro_id THEN
    RAISE EXCEPTION 'cliente_id fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.conversas (
    mensagem_id,
    remetente_enc,
    destinatario_enc,
    mensagem_enc,
    cliente_id
  ) VALUES (
    p_mensagem_id,
    private.encrypt_value(p_remetente),
    private.encrypt_value(p_destinatario),
    private.encrypt_value(p_mensagem),
    COALESCE(p_cliente_id, v_session_cadastro_id)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_selecionar_conversas_por_numero(text, integer, integer);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_conversas_por_numero(
  p_numero text,
  p_pagina integer DEFAULT 1,
  p_limite integer DEFAULT 100,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE(
  id uuid,
  mensagem_id text,
  remetente text,
  destinatario text,
  mensagem text,
  horario_mensagem timestamptz,
  cliente_id uuid
)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_numero_hash text := private.hash_phone_number(p_numero);
  v_pagina integer := COALESCE(p_pagina, 1);
  v_limite integer := LEAST(COALESCE(p_limite, 100), 300);
  v_offset integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_numero);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF v_numero_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: numero.'
      USING ERRCODE = '23502';
  END IF;

  IF v_numero_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'Numero fora do contexto da sessao.'
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

  v_offset := (v_pagina - 1) * v_limite;

  RETURN QUERY
  WITH matching_rows AS (
    SELECT c.id, c.horario_mensagem
    FROM private.conversas c
    WHERE c.remetente_hash = v_numero_hash

    UNION

    SELECT c.id, c.horario_mensagem
    FROM private.conversas c
    WHERE c.destinatario_hash = v_numero_hash
  ),
  paged_ids AS (
    SELECT mr.id
    FROM matching_rows mr
    ORDER BY mr.horario_mensagem DESC, mr.id DESC
    LIMIT v_limite
    OFFSET v_offset
  )
  SELECT
    c.id,
    c.mensagem_id,
    private.decrypt_value(c.remetente_enc),
    private.decrypt_value(c.destinatario_enc),
    private.decrypt_value(c.mensagem_enc),
    c.horario_mensagem,
    c.cliente_id
  FROM private.conversas c
  INNER JOIN paged_ids p ON p.id = c.id
  ORDER BY c.horario_mensagem DESC, c.id DESC;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_atualizar_cadastro(
  p_id uuid,
  p_nome text DEFAULT NULL,
  p_tipo text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL,
  p_empresa text DEFAULT NULL,
  p_cargo text DEFAULT NULL,
  p_sessao_token text DEFAULT NULL
) RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  UPDATE private.cadastro SET
    nome          = COALESCE(p_nome, nome),
    tipo          = COALESCE(p_tipo, tipo),
    email_enc     = CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     ELSE email_enc END,
    instagram_enc = CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) ELSE instagram_enc END,
    linkedin_enc  = CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  ELSE linkedin_enc END,
    empresa       = COALESCE(p_empresa, empresa),
    cargo         = COALESCE(p_cargo, cargo),
    updated_at    = NOW()
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_id(uuid);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_id(
  p_id uuid,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE(
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  created_at timestamptz,
  updated_at timestamptz
)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_phone_hash();

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
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.id = p_id;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_telefone(text);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_telefone(
  p_telefone text,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE(
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  created_at timestamptz,
  updated_at timestamptz
)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_hash text := private.hash_phone_number(p_telefone);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  IF v_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'Telefone fora do contexto da sessao.'
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
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.telefone_hash = v_hash;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(uuid, text, text, text, uuid);
CREATE OR REPLACE FUNCTION public.rpc_atualizar_conversa(
  p_id uuid,
  p_remetente text DEFAULT NULL,
  p_destinatario text DEFAULT NULL,
  p_mensagem text DEFAULT NULL,
  p_cliente_id uuid DEFAULT NULL,
  p_sessao_token text DEFAULT NULL
) RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_session_cadastro_id uuid := private.get_session_cadastro_id();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_phone_hash();

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_cliente_id IS NOT NULL
     AND v_session_cadastro_id IS NOT NULL
     AND p_cliente_id <> v_session_cadastro_id THEN
    RAISE EXCEPTION 'cliente_id fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE private.conversas SET
    remetente_enc    = CASE WHEN p_remetente    IS NOT NULL THEN private.encrypt_value(p_remetente)    ELSE remetente_enc END,
    destinatario_enc = CASE WHEN p_destinatario IS NOT NULL THEN private.encrypt_value(p_destinatario) ELSE destinatario_enc END,
    mensagem_enc     = CASE WHEN p_mensagem     IS NOT NULL THEN private.encrypt_value(p_mensagem)     ELSE mensagem_enc END,
    cliente_id       = COALESCE(p_cliente_id, cliente_id)
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_set_contexto_sessao(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(uuid, text, text, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(uuid, text, text, text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(uuid, text, text, text, uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_conversa(uuid, text, text, text, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM anon;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.activate_session_context(text, text) TO private_rpc_executor;