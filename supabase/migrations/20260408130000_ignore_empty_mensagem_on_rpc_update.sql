DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(text, text, uuid, text, text);

CREATE OR REPLACE FUNCTION public.rpc_atualizar_conversa(
  p_mensagem_id text,
  p_mensagem text DEFAULT NULL,
  p_cliente_id uuid DEFAULT NULL,
  p_status_mensagem text DEFAULT NULL,
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
    mensagem_enc     = CASE WHEN NULLIF(trim(p_mensagem), '') IS NOT NULL THEN private.encrypt_value(p_mensagem) ELSE mensagem_enc END,
    status_mensagem  = CASE WHEN p_status_mensagem IS NOT NULL THEN p_status_mensagem ELSE status_mensagem END
  WHERE mensagem_id = p_mensagem_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: mensagem_id %', p_mensagem_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text) TO authenticated;