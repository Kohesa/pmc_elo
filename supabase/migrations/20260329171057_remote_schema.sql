


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "private"."decrypt_value"("val" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
DECLARE
  dec TEXT;
BEGIN
  IF val IS NULL THEN
    RETURN NULL;
  END IF;

  dec := extensions.pgp_sym_decrypt(
    val::bytea,
    private.get_encryption_key()
  );

  RETURN dec;
END;
$$;


ALTER FUNCTION "private"."decrypt_value"("val" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."encrypt_value"("val" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
DECLARE
  enc TEXT;
BEGIN
  IF val IS NULL THEN
    RETURN NULL;
  END IF;

  enc := extensions.pgp_sym_encrypt(
    val,
    private.get_encryption_key()
  );

  RETURN enc;
END;
$$;


ALTER FUNCTION "private"."encrypt_value"("val" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."get_encryption_key"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public', 'vault'
    AS $$
DECLARE
  v_key text;
BEGIN
  SELECT ds.decrypted_secret
    INTO v_key
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'encryption_key'
  LIMIT 1;

  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RAISE EXCEPTION 'Segredo encryption_key nao encontrado no Supabase Vault.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_key;
END;
$$;


ALTER FUNCTION "private"."get_encryption_key"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."protect_telefone"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
BEGIN
  IF NEW.telefone_enc IS DISTINCT FROM OLD.telefone_enc
     OR NEW.telefone_hash IS DISTINCT FROM OLD.telefone_hash THEN
    RAISE EXCEPTION 'O telefone não pode ser alterado após o cadastro.'
      USING ERRCODE = '23507';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "private"."protect_telefone"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_automation"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'role') = 'automation';
$$;


ALTER FUNCTION "public"."is_automation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_chatbot"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'role') = 'chatbot';
$$;


ALTER FUNCTION "public"."is_chatbot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text" DEFAULT NULL::"text", "p_tipo" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_instagram" "text" DEFAULT NULL::"text", "p_linkedin" "text" DEFAULT NULL::"text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: id.'
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
    RAISE EXCEPTION 'Registro não encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;


ALTER FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text" DEFAULT NULL::"text", "p_destinatario" "text" DEFAULT NULL::"text", "p_mensagem" "text" DEFAULT NULL::"text", "p_cliente_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  UPDATE private.conversas SET
    remetente_enc    = CASE WHEN p_remetente    IS NOT NULL THEN private.encrypt_value(p_remetente)    ELSE remetente_enc END,
    destinatario_enc = CASE WHEN p_destinatario IS NOT NULL THEN private.encrypt_value(p_destinatario) ELSE destinatario_enc END,
    mensagem_enc     = CASE WHEN p_mensagem     IS NOT NULL THEN private.encrypt_value(p_mensagem)     ELSE mensagem_enc END,
    cliente_id       = COALESCE(p_cliente_id, cliente_id)
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro não encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;


ALTER FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text" DEFAULT NULL::"text", "p_tipo" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_instagram" "text" DEFAULT NULL::"text", "p_linkedin" "text" DEFAULT NULL::"text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_id UUID;
  v_hash TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_telefone IS NULL OR trim(p_telefone) = '' THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  -- 🔥 hash correto (Supabase)
  v_hash := encode(
    extensions.digest(convert_to(p_telefone, 'UTF8'), 'sha256'),
    'hex'
  );

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
    RAISE EXCEPTION 'Já existe cadastro com este telefone.'
      USING ERRCODE = '23505';
END;
$$;


ALTER FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_remetente IS NULL OR trim(p_remetente) = '' THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: remetente.'
      USING ERRCODE = '23502';
  END IF;

  IF p_destinatario IS NULL OR trim(p_destinatario) = '' THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: destinatario.'
      USING ERRCODE = '23502';
  END IF;

  IF p_mensagem IS NULL OR trim(p_mensagem) = '' THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: mensagem.'
      USING ERRCODE = '23502';
  END IF;

  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: cliente_id.'
      USING ERRCODE = '23502';
  END IF;

  INSERT INTO private.conversas (
    remetente_enc,
    destinatario_enc,
    mensagem_enc,
    cliente_id
  ) VALUES (
    private.encrypt_value(p_remetente),
    private.encrypt_value(p_destinatario),
    private.encrypt_value(p_mensagem),
    p_cliente_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") RETURNS TABLE("id" "uuid", "nome" "text", "tipo" "text", "telefone" "text", "email" "text", "instagram" "text", "linkedin" "text", "empresa" "text", "cargo" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: id.'
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


ALTER FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") RETURNS TABLE("id" "uuid", "nome" "text", "tipo" "text", "telefone" "text", "email" "text", "instagram" "text", "linkedin" "text", "empresa" "text", "cargo" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_hash TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuário não autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_telefone IS NULL OR trim(p_telefone) = '' THEN
    RAISE EXCEPTION 'Campo obrigatório ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  v_hash := encode(
    extensions.digest(convert_to(p_telefone, 'UTF8'), 'sha256'),
    'hex'
  );

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


ALTER FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "private"."base_conhecimento" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "tipo_relatorio" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "hora_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "documento" "text" NOT NULL,
    "area_empresa" "text" NOT NULL
);


ALTER TABLE "private"."base_conhecimento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."cadastro" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "nome" "text" NOT NULL,
    "tipo" "text",
    "telefone_enc" "text",
    "email_enc" "text",
    "instagram_enc" "text",
    "linkedin_enc" "text",
    "empresa" "text",
    "cargo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "telefone_hash" "text" NOT NULL
);


ALTER TABLE "private"."cadastro" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."conversas" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "conversa_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "remetente_enc" "text" NOT NULL,
    "destinatario_enc" "text" NOT NULL,
    "mensagem_enc" "text" NOT NULL,
    "horario_mensagem" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cliente_id" "uuid"
);


ALTER TABLE "private"."conversas" OWNER TO "postgres";


ALTER TABLE ONLY "private"."base_conhecimento"
    ADD CONSTRAINT "base_conhecimento_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "private"."cadastro"
    ADD CONSTRAINT "cadastro_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "private"."conversas"
    ADD CONSTRAINT "conversas_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_cadastro_created_at" ON "private"."cadastro" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_cadastro_updated_at" ON "private"."cadastro" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_conversas_cliente_data" ON "private"."conversas" USING "btree" ("cliente_id", "horario_mensagem" DESC);



CREATE INDEX "idx_conversas_conversa_id" ON "private"."conversas" USING "btree" ("conversa_id");



CREATE INDEX "idx_conversas_horario" ON "private"."conversas" USING "btree" ("horario_mensagem" DESC);



CREATE UNIQUE INDEX "ux_cadastro_telefone_hash" ON "private"."cadastro" USING "btree" ("telefone_hash");



CREATE OR REPLACE TRIGGER "trg_protect_telefone" BEFORE UPDATE ON "private"."cadastro" FOR EACH ROW EXECUTE FUNCTION "private"."protect_telefone"();



ALTER TABLE ONLY "private"."conversas"
    ADD CONSTRAINT "conversas_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "private"."cadastro"("id") ON DELETE SET NULL;



ALTER TABLE "private"."base_conhecimento" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "base_conhecimento_delete" ON "private"."base_conhecimento" FOR DELETE USING ("public"."is_automation"());



CREATE POLICY "base_conhecimento_insert" ON "private"."base_conhecimento" FOR INSERT WITH CHECK ("public"."is_automation"());



CREATE POLICY "base_conhecimento_select" ON "private"."base_conhecimento" FOR SELECT USING (("public"."is_chatbot"() OR "public"."is_automation"()));



CREATE POLICY "base_conhecimento_update" ON "private"."base_conhecimento" FOR UPDATE USING ("public"."is_automation"()) WITH CHECK ("public"."is_automation"());



ALTER TABLE "private"."cadastro" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cadastro_insert" ON "private"."cadastro" FOR INSERT WITH CHECK ("public"."is_chatbot"());



CREATE POLICY "cadastro_select" ON "private"."cadastro" FOR SELECT USING (("public"."is_chatbot"() OR "public"."is_automation"()));



CREATE POLICY "cadastro_update" ON "private"."cadastro" FOR UPDATE USING ("public"."is_chatbot"()) WITH CHECK ("public"."is_chatbot"());



ALTER TABLE "private"."conversas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "conversas_insert" ON "private"."conversas" FOR INSERT WITH CHECK ("public"."is_chatbot"());



CREATE POLICY "conversas_select" ON "private"."conversas" FOR SELECT USING (("public"."is_chatbot"() OR "public"."is_automation"()));



CREATE POLICY "conversas_update" ON "private"."conversas" FOR UPDATE USING ("public"."is_chatbot"()) WITH CHECK ("public"."is_chatbot"());



ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."is_automation"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_automation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_automation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_chatbot"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_chatbot"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_chatbot"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") TO "service_role";
























ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































