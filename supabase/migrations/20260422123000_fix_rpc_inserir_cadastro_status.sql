GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

DROP FUNCTION IF EXISTS public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.rpc_inserir_cadastro(
  p_telefone text DEFAULT NULL,
  p_nome text DEFAULT NULL,
  p_tipo text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL,
  p_empresa text DEFAULT NULL,
  p_cargo text DEFAULT NULL,
  p_sessao_token text DEFAULT NULL,
  p_alias text DEFAULT NULL,
  p_id_usuario_wa text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_id uuid;
  v_wa_hash text;
  v_tipo text;
  v_status text;
BEGIN
  -- Validar obrigatoriamente o id_usuario_wa para alinhar com o contexto de sessão do sistema
  IF p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  v_tipo := COALESCE(NULLIF(btrim(p_tipo), ''), 'Pessoa');
  v_status := 'aprovado';

  v_wa_hash := private.hash_value(p_id_usuario_wa);

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_id_usuario_wa);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  IF v_wa_hash <> private.get_session_wa_id_hash() THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.cadastro (
    nome,
    tipo,
    status,
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
    v_tipo,
    v_status,
    NULL,
    NULL,
    CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     END,
    CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) END,
    CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  END,
    p_empresa,
    p_cargo,
    CASE WHEN p_alias IS NOT NULL THEN private.encrypt_value(p_alias) END,
    CASE WHEN p_id_usuario_wa IS NOT NULL THEN private.encrypt_value(p_id_usuario_wa) END,
    v_wa_hash
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Ja existe cadastro com este telefone ou id_usuario_wa.'
      USING ERRCODE = '23505';
END;
$$;

ALTER FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_cadastro(text, text, text, text, text, text, text, text, text, text, text) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public  FROM private_rpc_executor;
