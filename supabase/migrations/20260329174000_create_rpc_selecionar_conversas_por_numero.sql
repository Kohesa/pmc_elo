DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'private_rpc_executor'
  ) THEN
    CREATE ROLE "private_rpc_executor"
      NOLOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      INHERIT
      NOREPLICATION
      NOBYPASSRLS;
  ELSE
    ALTER ROLE "private_rpc_executor"
      WITH NOLOGIN
           NOSUPERUSER
           NOCREATEDB
           NOCREATEROLE
           INHERIT
           NOREPLICATION
           NOBYPASSRLS;
  END IF;
END
$$;


GRANT "private_rpc_executor" TO "postgres";


GRANT USAGE ON SCHEMA "private" TO "private_rpc_executor";
GRANT CREATE ON SCHEMA "private" TO "private_rpc_executor";
GRANT USAGE ON SCHEMA "public" TO "private_rpc_executor";
GRANT CREATE ON SCHEMA "public" TO "private_rpc_executor";
GRANT USAGE ON SCHEMA "extensions" TO "private_rpc_executor";

GRANT SELECT, INSERT, UPDATE ON TABLE "private"."conversas" TO "private_rpc_executor";

GRANT EXECUTE ON FUNCTION "public"."is_chatbot"() TO "private_rpc_executor";
GRANT EXECUTE ON FUNCTION "public"."is_automation"() TO "private_rpc_executor";
GRANT EXECUTE ON FUNCTION "private"."encrypt_value"("val" "text") TO "private_rpc_executor";
GRANT EXECUTE ON FUNCTION "private"."decrypt_value"("val" "text") TO "private_rpc_executor";

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_namespace
    WHERE nspname = 'auth'
  ) THEN
    EXECUTE 'GRANT USAGE ON SCHEMA "auth" TO "private_rpc_executor"';
  END IF;

  IF to_regprocedure('auth.uid()') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION "auth"."uid"() TO "private_rpc_executor"';
  END IF;
END
$$;


CREATE OR REPLACE FUNCTION "private"."normalize_phone_number"("val" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT NULLIF(regexp_replace(trim(COALESCE(val, '')), '\D', '', 'g'), '');
$$;


ALTER FUNCTION "private"."normalize_phone_number"("val" "text") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "private"."hash_phone_number"("val" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT CASE
    WHEN private.normalize_phone_number(val) IS NULL THEN NULL
    ELSE encode(
      extensions.digest(
        convert_to(private.normalize_phone_number(val), 'UTF8'),
        'sha256'
      ),
      'hex'
    )
  END;
$$;


ALTER FUNCTION "private"."hash_phone_number"("val" "text") OWNER TO "private_rpc_executor";


ALTER TABLE "private"."conversas"
    ADD COLUMN IF NOT EXISTS "remetente_hash" "text",
    ADD COLUMN IF NOT EXISTS "destinatario_hash" "text";


UPDATE "private"."conversas"
SET
    "remetente_hash" = "private"."hash_phone_number"("private"."decrypt_value"("remetente_enc")),
    "destinatario_hash" = "private"."hash_phone_number"("private"."decrypt_value"("destinatario_enc"))
WHERE "remetente_hash" IS NULL
   OR "destinatario_hash" IS NULL;


CREATE INDEX IF NOT EXISTS "idx_conversas_remetente_hash_horario"
    ON "private"."conversas" USING "btree" ("remetente_hash", "horario_mensagem" DESC, "id" DESC);


CREATE INDEX IF NOT EXISTS "idx_conversas_destinatario_hash_horario"
    ON "private"."conversas" USING "btree" ("destinatario_hash", "horario_mensagem" DESC, "id" DESC);


CREATE OR REPLACE FUNCTION "private"."sync_conversas_lookup_hashes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
BEGIN
  NEW.remetente_hash := private.hash_phone_number(
    private.decrypt_value(NEW.remetente_enc)
  );

  NEW.destinatario_hash := private.hash_phone_number(
    private.decrypt_value(NEW.destinatario_enc)
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "private"."sync_conversas_lookup_hashes"() OWNER TO "private_rpc_executor";


DROP TRIGGER IF EXISTS "trg_sync_conversas_lookup_hashes" ON "private"."conversas";


CREATE TRIGGER "trg_sync_conversas_lookup_hashes"
BEFORE INSERT OR UPDATE OF "remetente_enc", "destinatario_enc" ON "private"."conversas"
FOR EACH ROW EXECUTE FUNCTION "private"."sync_conversas_lookup_hashes"();


CREATE OR REPLACE FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text" DEFAULT NULL::"text", "p_destinatario" "text" DEFAULT NULL::"text", "p_mensagem" "text" DEFAULT NULL::"text", "p_cliente_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuario nao autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_remetente IS NOT NULL AND private.hash_phone_number(p_remetente) IS NULL THEN
    RAISE EXCEPTION 'Parametro invalido: remetente deve conter um numero.'
      USING ERRCODE = '22023';
  END IF;

  IF p_destinatario IS NOT NULL AND private.hash_phone_number(p_destinatario) IS NULL THEN
    RAISE EXCEPTION 'Parametro invalido: destinatario deve conter um numero.'
      USING ERRCODE = '22023';
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


ALTER FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuario nao autenticado.'
      USING ERRCODE = '42501';
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

  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: cliente_id.'
      USING ERRCODE = '23502';
  END IF;

  IF private.hash_phone_number(p_remetente) IS NULL THEN
    RAISE EXCEPTION 'Parametro invalido: remetente deve conter um numero.'
      USING ERRCODE = '22023';
  END IF;

  IF private.hash_phone_number(p_destinatario) IS NULL THEN
    RAISE EXCEPTION 'Parametro invalido: destinatario deve conter um numero.'
      USING ERRCODE = '22023';
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


ALTER FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_selecionar_conversas_por_numero"(
    "p_numero" "text",
    "p_pagina" integer DEFAULT 1,
    "p_limite" integer DEFAULT 100
) RETURNS TABLE(
    "id" "uuid",
    "conversa_id" "uuid",
    "remetente" "text",
    "destinatario" "text",
    "mensagem" "text",
    "horario_mensagem" timestamp with time zone,
    "cliente_id" "uuid"
)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_numero TEXT := trim(p_numero);
  v_numero_hash TEXT := private.hash_phone_number(p_numero);
  v_pagina INTEGER := COALESCE(p_pagina, 1);
  v_limite INTEGER := LEAST(COALESCE(p_limite, 100), 300);
  v_offset INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuario nao autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF p_numero IS NULL OR v_numero = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: numero.'
      USING ERRCODE = '23502';
  END IF;

  IF v_numero_hash IS NULL THEN
    RAISE EXCEPTION 'Parametro invalido: numero deve conter digitos validos.'
      USING ERRCODE = '22023';
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
    SELECT
      c.id,
      c.horario_mensagem
    FROM private.conversas c
    WHERE c.remetente_hash = v_numero_hash

    UNION

    SELECT
      c.id,
      c.horario_mensagem
    FROM private.conversas c
    WHERE c.destinatario_hash = v_numero_hash
  ),
  paged_ids AS (
    SELECT
      mr.id
    FROM matching_rows mr
    ORDER BY mr.horario_mensagem DESC, mr.id DESC
    LIMIT v_limite
    OFFSET v_offset
  )
  SELECT
    c.id,
    c.conversa_id,
    private.decrypt_value(c.remetente_enc),
    private.decrypt_value(c.destinatario_enc),
    private.decrypt_value(c.mensagem_enc),
    c.horario_mensagem,
    c.cliente_id
  FROM private.conversas c
  INNER JOIN paged_ids p
          ON p.id = c.id
  ORDER BY c.horario_mensagem DESC, c.id DESC;
END;
$$;


ALTER FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) OWNER TO "private_rpc_executor";


REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) TO "authenticated";


REVOKE CREATE ON SCHEMA "private" FROM "private_rpc_executor";
REVOKE CREATE ON SCHEMA "public" FROM "private_rpc_executor";
