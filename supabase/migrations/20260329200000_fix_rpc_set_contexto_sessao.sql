-- Fix for rpc_set_contexto_sessao and require_session_phone_hash to remove auth.uid() check causing permission denied

CREATE OR REPLACE FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
DECLARE
  v_hash TEXT := private.hash_phone_number(p_telefone);
BEGIN
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_phone_hash', v_hash, false);
END;
$$;

ALTER FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") OWNER TO "private_rpc_executor";

CREATE OR REPLACE FUNCTION "private"."require_session_phone_hash"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  v_hash TEXT := private.get_session_phone_hash();
BEGIN
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Contexto da sessao nao definido. Chame a RPC de contexto antes da operacao.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_hash;
END;
$$;

ALTER FUNCTION "private"."require_session_phone_hash"() OWNER TO "private_rpc_executor";