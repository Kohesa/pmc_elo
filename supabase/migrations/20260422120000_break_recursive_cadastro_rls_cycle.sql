-- A policy de cadastro valida somente o identificador da sessao ativa.

DROP POLICY IF EXISTS cadastro_select ON private.cadastro;

CREATE POLICY cadastro_select ON private.cadastro
  FOR SELECT
  USING (
    (public.request_jwt_sub() IS NOT NULL AND auth_user_id = public.request_jwt_sub())
    OR
    (private.get_session_wa_id_hash() IS NOT NULL AND id_usuario_wa_hash = private.get_session_wa_id_hash())
  );
