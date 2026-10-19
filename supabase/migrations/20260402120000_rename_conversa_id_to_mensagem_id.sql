ALTER TABLE private.conversas
  RENAME COLUMN conversa_id TO mensagem_id;

ALTER TABLE private.conversas
  ALTER COLUMN mensagem_id DROP DEFAULT,
  ALTER COLUMN mensagem_id TYPE text USING mensagem_id::text;

ALTER INDEX IF EXISTS private.idx_conversas_conversa_id
  RENAME TO idx_conversas_mensagem_id;

DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id text,
  p_remetente text,
  p_destinatario text,
  p_mensagem text,
  p_cliente_id uuid
) RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'private', 'public'
    SET row_security TO 'on'
AS $$
DECLARE
  v_id UUID;
  v_session_cadastro_id UUID := private.get_session_cadastro_id();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.'
      USING ERRCODE = '28000';
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

REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid) TO authenticated;