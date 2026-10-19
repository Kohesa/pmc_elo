ALTER TABLE private.conversas
  ADD COLUMN IF NOT EXISTS horario_mensagem_api timestamptz,
  ADD COLUMN IF NOT EXISTS status_mensagem text;

UPDATE private.conversas
SET horario_mensagem_api = horario_mensagem
WHERE horario_mensagem_api IS NULL;

DROP INDEX IF EXISTS idx_conversas_remetente_hash_horario;
CREATE INDEX IF NOT EXISTS idx_conversas_remetente_hash_horario_api
  ON private.conversas USING btree (remetente_hash, COALESCE(horario_mensagem_api, horario_mensagem) DESC, id DESC);

DROP INDEX IF EXISTS idx_conversas_destinatario_hash_horario;
CREATE INDEX IF NOT EXISTS idx_conversas_destinatario_hash_horario_api
  ON private.conversas USING btree (destinatario_hash, COALESCE(horario_mensagem_api, horario_mensagem) DESC, id DESC);

DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, text);
CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id text,
  p_remetente text,
  p_destinatario text,
  p_mensagem text,
  p_cliente_id uuid,
  p_horario_mensagem_api timestamptz DEFAULT NULL,
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
    cliente_id,
    horario_mensagem_api,
    status_mensagem
  ) VALUES (
    p_mensagem_id,
    private.encrypt_value(p_remetente),
    private.encrypt_value(p_destinatario),
    private.encrypt_value(p_mensagem),
    COALESCE(p_cliente_id, v_session_cadastro_id),
    p_horario_mensagem_api,
    NULL
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_selecionar_conversas_por_numero(text, integer, integer, text);
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
  horario_mensagem_api timestamptz,
  status_mensagem text,
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
    SELECT c.id, COALESCE(c.horario_mensagem_api, c.horario_mensagem) AS horario_ordenacao
    FROM private.conversas c
    WHERE c.remetente_hash = v_numero_hash

    UNION

    SELECT c.id, COALESCE(c.horario_mensagem_api, c.horario_mensagem) AS horario_ordenacao
    FROM private.conversas c
    WHERE c.destinatario_hash = v_numero_hash
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
    private.decrypt_value(c.remetente_enc),
    private.decrypt_value(c.destinatario_enc),
    private.decrypt_value(c.mensagem_enc),
    c.horario_mensagem,
    c.horario_mensagem_api,
    c.status_mensagem,
    c.cliente_id
  FROM private.conversas c
  INNER JOIN paged_ids p ON p.id = c.id
  ORDER BY COALESCE(c.horario_mensagem_api, c.horario_mensagem) DESC, c.id DESC;
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(uuid, text, text, text, uuid, text);
CREATE OR REPLACE FUNCTION public.rpc_atualizar_conversa(
  p_mensagem_id text,
  p_remetente text DEFAULT NULL,
  p_destinatario text DEFAULT NULL,
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
    remetente_enc    = CASE WHEN p_remetente      IS NOT NULL THEN private.encrypt_value(p_remetente)      ELSE remetente_enc END,
    destinatario_enc = CASE WHEN p_destinatario   IS NOT NULL THEN private.encrypt_value(p_destinatario)   ELSE destinatario_enc END,
    mensagem_enc     = CASE WHEN p_mensagem       IS NOT NULL THEN private.encrypt_value(p_mensagem)       ELSE mensagem_enc END,
    cliente_id       = COALESCE(p_cliente_id, cliente_id),
    status_mensagem  = CASE WHEN p_status_mensagem IS NOT NULL THEN p_status_mensagem ELSE status_mensagem END
  WHERE mensagem_id = p_mensagem_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: mensagem_id %', p_mensagem_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, text, text, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, text, text, uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, text, text, uuid, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_conversa(text, text, text, text, uuid, text, text) TO authenticated;


REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, timestamptz, text) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text) TO authenticated;