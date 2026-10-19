-- Harden key access for SECURITY DEFININER RPC architecture.
-- The Supabase Vault contract used by the project is vault.decrypted_secrets.

-- 1) Centralized key retrieval. The function runs as postgres and only exposes
-- the specific encryption key to the private crypto boundary.
CREATE OR REPLACE FUNCTION "private"."get_encryption_key"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public', 'vault'
    AS $$
DECLARE
  v_key TEXT;
BEGIN
  SELECT ds.decrypted_secret
    INTO v_key
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'encryption_key'
  LIMIT 1;

  IF v_key IS NULL OR trim(v_key) = '' THEN
    RAISE EXCEPTION 'Segredo encryption_key nao encontrado no Supabase Vault.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_key;
END;
$$;

ALTER FUNCTION "private"."get_encryption_key"() OWNER TO "postgres";


-- 2) Least privilege on private crypto functions
REVOKE ALL ON FUNCTION "private"."get_encryption_key"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "private"."get_encryption_key"() FROM "anon";
REVOKE ALL ON FUNCTION "private"."get_encryption_key"() FROM "authenticated";
REVOKE ALL ON FUNCTION "private"."get_encryption_key"() FROM "service_role";
GRANT EXECUTE ON FUNCTION "private"."get_encryption_key"() TO "private_rpc_executor";

REVOKE ALL ON FUNCTION "private"."encrypt_value"("val" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "private"."encrypt_value"("val" "text") FROM "anon";
REVOKE ALL ON FUNCTION "private"."encrypt_value"("val" "text") FROM "authenticated";
REVOKE ALL ON FUNCTION "private"."encrypt_value"("val" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "private"."encrypt_value"("val" "text") TO "private_rpc_executor";

REVOKE ALL ON FUNCTION "private"."decrypt_value"("val" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "private"."decrypt_value"("val" "text") FROM "anon";
REVOKE ALL ON FUNCTION "private"."decrypt_value"("val" "text") FROM "authenticated";
REVOKE ALL ON FUNCTION "private"."decrypt_value"("val" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "private"."decrypt_value"("val" "text") TO "private_rpc_executor";


-- 3) Keep RPC-only access pattern explicit
REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"(
  "p_telefone" "text",
  "p_nome" "text",
  "p_tipo" "text",
  "p_email" "text",
  "p_instagram" "text",
  "p_linkedin" "text",
  "p_empresa" "text",
  "p_cargo" "text"
) FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"(
  "p_telefone" "text",
  "p_nome" "text",
  "p_tipo" "text",
  "p_email" "text",
  "p_instagram" "text",
  "p_linkedin" "text",
  "p_empresa" "text",
  "p_cargo" "text"
) FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"(
  "p_telefone" "text",
  "p_nome" "text",
  "p_tipo" "text",
  "p_email" "text",
  "p_instagram" "text",
  "p_linkedin" "text",
  "p_empresa" "text",
  "p_cargo" "text"
) FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_inserir_cadastro"(
  "p_telefone" "text",
  "p_nome" "text",
  "p_tipo" "text",
  "p_email" "text",
  "p_instagram" "text",
  "p_linkedin" "text",
  "p_empresa" "text",
  "p_cargo" "text"
) TO "authenticated";
