GRANT "private_rpc_executor" TO "postgres";

GRANT USAGE ON SCHEMA auth TO authenticated;

GRANT USAGE ON SCHEMA "private" TO "private_rpc_executor";
GRANT CREATE ON SCHEMA "private" TO "private_rpc_executor";
GRANT USAGE ON SCHEMA "public" TO "private_rpc_executor";
GRANT CREATE ON SCHEMA "public" TO "private_rpc_executor";
GRANT SELECT, INSERT, UPDATE ON TABLE "private"."cadastro" TO "private_rpc_executor";

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
REVOKE ALL ON FUNCTION "private"."get_encryption_key"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "private"."get_encryption_key"() TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "private"."get_session_phone_hash"() RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT NULLIF(current_setting('app.session_phone_hash', true), '');
$$;


ALTER FUNCTION "private"."get_session_phone_hash"() OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "private"."require_session_phone_hash"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  v_hash TEXT := private.get_session_phone_hash();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuario nao autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Contexto da sessao nao definido. Chame a RPC de contexto antes da operacao.'
      USING ERRCODE = '22023';
  END IF;

  RETURN v_hash;
END;
$$;


ALTER FUNCTION "private"."require_session_phone_hash"() OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "private"."get_session_cadastro_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
  SELECT c.id
  FROM private.cadastro c
  WHERE c.telefone_hash = private.get_session_phone_hash()
  LIMIT 1;
$$;


ALTER FUNCTION "private"."get_session_cadastro_id"() OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    AS $$
DECLARE
  v_hash TEXT := private.hash_phone_number(p_telefone);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: usuario nao autenticado.'
      USING ERRCODE = '42501';
  END IF;

  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone.'
      USING ERRCODE = '23502';
  END IF;

  PERFORM set_config('app.session_phone_hash', v_hash, false);
END;
$$;


ALTER FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") OWNER TO "private_rpc_executor";


DROP POLICY IF EXISTS "cadastro_insert" ON "private"."cadastro";
DROP POLICY IF EXISTS "cadastro_select" ON "private"."cadastro";
DROP POLICY IF EXISTS "cadastro_update" ON "private"."cadastro";

CREATE POLICY "cadastro_insert" ON "private"."cadastro"
  FOR INSERT
  WITH CHECK (
    private.get_session_phone_hash() IS NOT NULL
    AND telefone_hash = private.get_session_phone_hash()
  );

CREATE POLICY "cadastro_select" ON "private"."cadastro"
  FOR SELECT
  USING (
    private.get_session_phone_hash() IS NOT NULL
    AND telefone_hash = private.get_session_phone_hash()
  );

CREATE POLICY "cadastro_update" ON "private"."cadastro"
  FOR UPDATE
  USING (
    private.get_session_phone_hash() IS NOT NULL
    AND telefone_hash = private.get_session_phone_hash()
  )
  WITH CHECK (
    private.get_session_phone_hash() IS NOT NULL
    AND telefone_hash = private.get_session_phone_hash()
  );


DROP POLICY IF EXISTS "conversas_insert" ON "private"."conversas";
DROP POLICY IF EXISTS "conversas_select" ON "private"."conversas";
DROP POLICY IF EXISTS "conversas_update" ON "private"."conversas";

CREATE POLICY "conversas_insert" ON "private"."conversas"
  FOR INSERT
  WITH CHECK (
    private.get_session_phone_hash() IS NOT NULL
    AND (
      remetente_hash = private.get_session_phone_hash()
      OR destinatario_hash = private.get_session_phone_hash()
    )
  );

CREATE POLICY "conversas_select" ON "private"."conversas"
  FOR SELECT
  USING (
    private.get_session_phone_hash() IS NOT NULL
    AND (
      remetente_hash = private.get_session_phone_hash()
      OR destinatario_hash = private.get_session_phone_hash()
    )
  );

CREATE POLICY "conversas_update" ON "private"."conversas"
  FOR UPDATE
  USING (
    private.get_session_phone_hash() IS NOT NULL
    AND (
      remetente_hash = private.get_session_phone_hash()
      OR destinatario_hash = private.get_session_phone_hash()
    )
  )
  WITH CHECK (
    private.get_session_phone_hash() IS NOT NULL
    AND (
      remetente_hash = private.get_session_phone_hash()
      OR destinatario_hash = private.get_session_phone_hash()
    )
  );


CREATE OR REPLACE FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text" DEFAULT NULL::"text", "p_tipo" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_instagram" "text" DEFAULT NULL::"text", "p_linkedin" "text" DEFAULT NULL::"text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_id UUID;
  v_hash TEXT := private.hash_phone_number(p_telefone);
BEGIN
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


ALTER FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_id UUID;
  v_session_cadastro_id UUID := private.get_session_cadastro_id();
BEGIN
  PERFORM private.require_session_phone_hash();

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
    remetente_enc,
    destinatario_enc,
    mensagem_enc,
    cliente_id
  ) VALUES (
    private.encrypt_value(p_remetente),
    private.encrypt_value(p_destinatario),
    private.encrypt_value(p_mensagem),
    COALESCE(p_cliente_id, v_session_cadastro_id)
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
  v_numero_hash TEXT := private.hash_phone_number(p_numero);
  v_pagina INTEGER := COALESCE(p_pagina, 1);
  v_limite INTEGER := LEAST(COALESCE(p_limite, 100), 300);
  v_offset INTEGER;
BEGIN
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


REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_set_contexto_sessao"("p_telefone" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_inserir_cadastro"("p_telefone" "text", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_inserir_conversa"("p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_selecionar_conversas_por_numero"("p_numero" "text", "p_pagina" integer, "p_limite" integer) TO "authenticated";


CREATE OR REPLACE FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text" DEFAULT NULL::"text", "p_tipo" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_instagram" "text" DEFAULT NULL::"text", "p_linkedin" "text" DEFAULT NULL::"text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
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


ALTER FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") RETURNS TABLE("id" "uuid", "nome" "text", "tipo" "text", "telefone" "text", "email" "text", "instagram" "text", "linkedin" "text", "empresa" "text", "cargo" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
BEGIN
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


ALTER FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") RETURNS TABLE("id" "uuid", "nome" "text", "tipo" "text", "telefone" "text", "email" "text", "instagram" "text", "linkedin" "text", "empresa" "text", "cargo" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_hash TEXT := private.hash_phone_number(p_telefone);
BEGIN
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


ALTER FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") OWNER TO "private_rpc_executor";


CREATE OR REPLACE FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text" DEFAULT NULL::"text", "p_destinatario" "text" DEFAULT NULL::"text", "p_mensagem" "text" DEFAULT NULL::"text", "p_cliente_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'public'
    SET "row_security" TO 'on'
    AS $$
DECLARE
  v_session_cadastro_id UUID := private.get_session_cadastro_id();
BEGIN
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


ALTER FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") OWNER TO "private_rpc_executor";


REVOKE ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_atualizar_cadastro"("p_id" "uuid", "p_nome" "text", "p_tipo" "text", "p_email" "text", "p_instagram" "text", "p_linkedin" "text", "p_empresa" "text", "p_cargo" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_selecionar_cadastro_por_id"("p_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_selecionar_cadastro_por_telefone"("p_telefone" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "anon";
REVOKE ALL ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") FROM "service_role";
GRANT EXECUTE ON FUNCTION "public"."rpc_atualizar_conversa"("p_id" "uuid", "p_remetente" "text", "p_destinatario" "text", "p_mensagem" "text", "p_cliente_id" "uuid") TO "authenticated";


REVOKE CREATE ON SCHEMA "private" FROM "private_rpc_executor";
REVOKE CREATE ON SCHEMA "public" FROM "private_rpc_executor";
