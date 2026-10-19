-- Fase 2: Converter RPCs antigas de JWT para S2S puro.
-- Remove todos os checks de auth.uid(), altera GRANTs de authenticated para service_role.
-- Sessao continua sendo validada por activate_session_context (sessao_token criptografado).
-- rpc_set_contexto_sessao passa a exigir p_token_s2s em vez de JWT.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

-- Adicionar colunas novas na tabela cadastro
ALTER TABLE private.cadastro ADD COLUMN IF NOT EXISTS alias_enc text;
ALTER TABLE private.cadastro ADD COLUMN IF NOT EXISTS id_usuario_wa_enc text;
ALTER TABLE private.cadastro ADD COLUMN IF NOT EXISTS id_usuario_wa_hash text UNIQUE;

-- Na Elo todo cadastro nasce aprovado. O bloqueio continua disponível para
-- operação manual ou automação no backend.
ALTER TABLE private.cadastro DROP CONSTRAINT IF EXISTS cadastro_status_check;
ALTER TABLE private.cadastro DROP CONSTRAINT IF EXISTS check_tipo;
ALTER TABLE private.cadastro DROP CONSTRAINT IF EXISTS check_status;
UPDATE private.cadastro
SET status = 'aprovado'
WHERE status IS NULL OR status <> 'bloqueado';
ALTER TABLE private.cadastro
  ADD CONSTRAINT cadastro_status_check CHECK (status IN ('aprovado', 'bloqueado'));

-- Tabela de nonces S2S — invalida tokens apos uso unico (previne replay attacks)
CREATE TABLE IF NOT EXISTS private.nonces_s2s (
  nonce      text        PRIMARY KEY,
  client_id  text        NOT NULL,
  expires_at timestamptz NOT NULL,
  usado_em   timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_nonces_s2s_expires_at
  ON private.nonces_s2s (expires_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.nonces_s2s TO private_rpc_executor;

-- Recriar rpc_autenticar_s2s: scope + bcrypt (fallback SHA-256) + HMAC + nonce
-- Payload (antes de criptografar): client_id|exp_epoch|nonce|scope|hmac_sha256
-- bcrypt detectado pelo prefixo '$2'; SHA-256 aceito como legado com aviso via check
DROP FUNCTION IF EXISTS public.rpc_autenticar_s2s(text, text);
CREATE OR REPLACE FUNCTION public.rpc_autenticar_s2s(
  p_client_id     text,
  p_client_secret text,
  p_scope         text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'off'
AS $$
DECLARE
  v_secret_hash   text;
  v_nonce         text;
  v_enc_key       text;
  v_payload       text;
  v_hmac          text;
  v_exp_epoch     bigint      := extract(epoch from (now() + interval '60 seconds'))::bigint;
  v_expires_at    timestamptz := now() + interval '60 seconds';
  v_scopes_validos text[] := ARRAY[
    'identificar', 'set_contexto', 'registrar_tokens'
  ];
BEGIN
  IF p_client_id IS NULL OR btrim(p_client_id) = '' THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  IF p_client_secret IS NULL OR btrim(p_client_secret) = '' THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  -- Validar scope antes de qualquer acesso ao banco
  IF p_scope IS NULL OR btrim(p_scope) = '' OR NOT (p_scope = ANY(v_scopes_validos)) THEN
    RAISE EXCEPTION 'Acesso negado: scope invalido ou ausente.'
      USING ERRCODE = '42501';
  END IF;

  SELECT client_secret_hash INTO v_secret_hash
  FROM private.credenciais_s2s
  WHERE client_id = p_client_id AND ativo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  -- Verificar secret: bcrypt (novo padrao) com fallback SHA-256 para credenciais legadas
  -- Hashes bcrypt sempre iniciam com '$2'. Para migrar, recadastrar via bcrypt.
  IF left(v_secret_hash, 2) = '$2' THEN
    IF extensions.crypt(p_client_secret, v_secret_hash) IS DISTINCT FROM v_secret_hash THEN
      RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF v_secret_hash IS DISTINCT FROM encode(extensions.digest(p_client_secret, 'sha256'), 'hex') THEN
      RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Nonce de 16 bytes aleatorios (128 bits) — uso unico, invalida token apos consumo
  v_nonce := encode(extensions.gen_random_bytes(16), 'hex');

  INSERT INTO private.nonces_s2s (nonce, client_id, expires_at)
  VALUES (v_nonce, p_client_id, v_expires_at);

  -- HMAC do payload com a chave do Vault (defesa em profundidade: integridade independente do PGP)
  v_enc_key := private.get_encryption_key();
  v_payload := p_client_id || '|' || v_exp_epoch::text || '|' || v_nonce || '|' || p_scope;
  v_hmac    := encode(extensions.hmac(v_payload, v_enc_key, 'sha256'), 'hex');

  -- Token final: payload|hmac — tudo criptografado com PGP
  RETURN private.encrypt_value(v_payload || '|' || v_hmac);
END;
$$;

ALTER FUNCTION public.rpc_autenticar_s2s(text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_autenticar_s2s(text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_autenticar_s2s(text, text, text) TO service_role;

-- Recriar validar_token_s2s: nonce unico + tolerancia de timestamp + HMAC + scope
-- VOLATILE (era STABLE): faz UPDATE/DELETE na tabela de nonces
CREATE OR REPLACE FUNCTION private.validar_token_s2s(
  p_token          text,
  p_scope_esperado text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
SET row_security TO 'off'
AS $$
DECLARE
  v_decrypted  text;
  v_parts      text[];
  v_client_id  text;
  v_exp        bigint;
  v_nonce      text;
  v_scope      text;
  v_hmac_recv  text;
  v_payload    text;
  v_enc_key    text;
  v_hmac_calc  text;
  v_now_epoch  bigint := extract(epoch from now())::bigint;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RAISE EXCEPTION 'Acesso negado: token S2S ausente.'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_decrypted := private.decrypt_value(p_token);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Acesso negado: token S2S invalido.'
      USING ERRCODE = '42501';
  END;

  v_parts := string_to_array(v_decrypted, '|');

  -- Formato obrigatorio: client_id|exp_epoch|nonce|scope|hmac (5 partes)
  IF array_length(v_parts, 1) < 5 THEN
    RAISE EXCEPTION 'Acesso negado: formato de token S2S invalido.'
      USING ERRCODE = '42501';
  END IF;

  v_client_id := v_parts[1];
  v_nonce     := v_parts[3];
  v_scope     := v_parts[4];
  v_hmac_recv := v_parts[5];

  BEGIN
    v_exp := v_parts[2]::bigint;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Acesso negado: token S2S com expiracao invalida.'
      USING ERRCODE = '42501';
  END;

  -- 1. Token expirado
  IF v_exp < v_now_epoch THEN
    RAISE EXCEPTION 'Acesso negado: token S2S expirado.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Tolerancia de timestamp: exp nao pode ser mais de 90s no futuro
  --    (TTL emitido = 60s + 30s de tolerancia de clock skew)
  IF v_exp > v_now_epoch + 90 THEN
    RAISE EXCEPTION 'Acesso negado: token S2S com timestamp invalido.'
      USING ERRCODE = '42501';
  END IF;

  -- 3. Nonce presente
  IF v_nonce IS NULL OR btrim(v_nonce) = '' THEN
    RAISE EXCEPTION 'Acesso negado: token S2S sem nonce.'
      USING ERRCODE = '42501';
  END IF;

  -- 4. Verificar HMAC (defesa em profundidade — integridade independente do PGP)
  v_enc_key   := private.get_encryption_key();
  v_payload   := v_client_id || '|' || v_exp::text || '|' || v_nonce || '|' || v_scope;
  v_hmac_calc := encode(extensions.hmac(v_payload, v_enc_key, 'sha256'), 'hex');

  IF v_hmac_calc IS DISTINCT FROM v_hmac_recv THEN
    RAISE EXCEPTION 'Acesso negado: assinatura do token S2S invalida.'
      USING ERRCODE = '42501';
  END IF;

  -- 5. Validar scope, se informado pelo chamador
  IF p_scope_esperado IS NOT NULL AND v_scope IS DISTINCT FROM p_scope_esperado THEN
    RAISE EXCEPTION 'Acesso negado: scope do token S2S invalido.'
      USING ERRCODE = '42501';
  END IF;

  -- 6. Consumir nonce atomicamente — rejeita se ja usado ou inexistente
  UPDATE private.nonces_s2s
  SET usado_em = now()
  WHERE nonce     = v_nonce
    AND client_id = v_client_id
    AND usado_em  IS NULL
    AND expires_at > now();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acesso negado: token S2S invalido ou ja utilizado.'
      USING ERRCODE = '42501';
  END IF;

  -- 7. Limpeza inline de nonces expirados (sem custo extra de job externo)
  DELETE FROM private.nonces_s2s
  WHERE expires_at < now() - interval '5 minutes';

  PERFORM set_config('app.session_s2s_validated', 'true', false);
END;
$$;

-- 1) private.activate_session_context — remove auth.uid() check
CREATE OR REPLACE FUNCTION private.activate_session_context(
  p_sessao_token text,
  p_telefone text DEFAULT NULL,
  p_id_usuario_wa text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_payload text;
  v_hash text;
  v_exp_epoch bigint;
  v_phone_hash text;
  v_id_hash text;
BEGIN
  IF p_sessao_token IS NULL OR trim(p_sessao_token) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: sessao_token.'
      USING ERRCODE = '23502';
  END IF;

  -- Validar obrigatoriamente id (telefone ou id_usuario_wa)
  IF (p_telefone IS NULL OR trim(p_telefone) = '') AND (p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone ou id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  BEGIN
    v_payload := private.decrypt_value(p_sessao_token);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION 'Sessao invalida ou expirada.'
        USING ERRCODE = '42501';
  END;

  v_hash := split_part(v_payload, '|', 1);

  BEGIN
    v_exp_epoch := split_part(v_payload, '|', 2)::bigint;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION 'Sessao invalida ou expirada.'
        USING ERRCODE = '42501';
  END;

  IF v_hash IS NULL OR trim(v_hash) = '' OR v_exp_epoch IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  IF v_exp_epoch <= extract(epoch FROM now())::bigint THEN
    RAISE EXCEPTION 'Sessao invalida ou expirada.'
      USING ERRCODE = '42501';
  END IF;

  -- Validar se o hash corresponde ao telefone ou id_usuario_wa passado
  IF p_id_usuario_wa IS NOT NULL AND trim(p_id_usuario_wa) <> '' THEN
    v_id_hash := private.hash_value(p_id_usuario_wa); -- Assumindo função hash_value para id
    IF v_id_hash <> v_hash THEN
      RAISE EXCEPTION 'id_usuario_wa fora do contexto da sessao.'
        USING ERRCODE = '42501';
    END IF;
  ELSIF p_telefone IS NOT NULL AND trim(p_telefone) <> '' THEN
    v_phone_hash := private.hash_phone_number(p_telefone);
    IF v_phone_hash <> v_hash THEN
      RAISE EXCEPTION 'Telefone fora do contexto da sessao.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  PERFORM set_config('app.session_phone_hash', v_hash, false);

  RETURN v_hash;
END;
$$;

REVOKE ALL ON FUNCTION private.activate_session_context(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text, text) FROM anon;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.activate_session_context(text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.activate_session_context(text, text, text) TO private_rpc_executor;

-- 2) rpc_set_contexto_sessao — troca JWT por p_token_s2s obrigatorio
DROP FUNCTION IF EXISTS public.rpc_set_contexto_sessao(text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_set_contexto_sessao(
  p_token_s2s text,
  p_telefone text DEFAULT NULL,
  p_sessao_token text DEFAULT NULL,
  p_id_usuario_wa text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_hash text;
  v_exp_epoch bigint := extract(epoch FROM (now() + interval '60 seconds'))::bigint;
  v_payload text;
  v_novo_sessao_token text;
BEGIN
  PERFORM private.validar_token_s2s(p_token_s2s, 'set_contexto');

  -- Validar obrigatoriamente telefone ou id_usuario_wa
  IF (p_telefone IS NULL OR trim(p_telefone) = '') AND (p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone ou id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  -- Definir hash baseado no id_usuario_wa ou telefone
  IF p_id_usuario_wa IS NOT NULL AND trim(p_id_usuario_wa) <> '' THEN
    v_hash := private.hash_value(p_id_usuario_wa);
  ELSE
    v_hash := private.hash_phone_number(p_telefone);
  END IF;

  IF p_sessao_token IS NOT NULL AND trim(p_sessao_token) <> '' THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone, p_id_usuario_wa);
  END IF;

  v_payload := v_hash || '|' || v_exp_epoch::text;
  v_novo_sessao_token := private.encrypt_value(v_payload);

  PERFORM set_config('app.session_phone_hash', v_hash, false);

  RETURN v_novo_sessao_token;
END;
$$;

ALTER FUNCTION public.rpc_set_contexto_sessao(text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_set_contexto_sessao(text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_contexto_sessao(text, text, text, text) TO service_role;

-- 3) rpc_inserir_cadastro — remove auth.uid() check
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
  v_hash text;
BEGIN
  -- Validar obrigatoriamente telefone ou id_usuario_wa
  IF (p_telefone IS NULL OR trim(p_telefone) = '') AND (p_id_usuario_wa IS NULL OR trim(p_id_usuario_wa) = '') THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: telefone ou id_usuario_wa.'
      USING ERRCODE = '23502';
  END IF;

  -- Definir hash baseado no id_usuario_wa ou telefone
  IF p_id_usuario_wa IS NOT NULL AND trim(p_id_usuario_wa) <> '' THEN
    v_hash := private.hash_value(p_id_usuario_wa);
  ELSE
    v_hash := private.hash_phone_number(p_telefone);
  END IF;

  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone, p_id_usuario_wa);
  END IF;

  PERFORM private.require_session_wa_id_hash();

  IF v_hash <> private.get_session_phone_hash() THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
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
    cargo,
    alias_enc,
    id_usuario_wa_enc,
    id_usuario_wa_hash
  ) VALUES (
    p_nome,
    p_tipo,
    CASE WHEN p_telefone IS NOT NULL THEN private.encrypt_value(p_telefone) END,
    v_hash,
    CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     END,
    CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) END,
    CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  END,
    p_empresa,
    p_cargo,
    CASE WHEN p_alias IS NOT NULL THEN private.encrypt_value(p_alias) END,
    CASE WHEN p_id_usuario_wa IS NOT NULL THEN private.encrypt_value(p_id_usuario_wa) END,
    CASE WHEN p_id_usuario_wa IS NOT NULL THEN private.hash_value(p_id_usuario_wa) END
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

-- 4) rpc_inserir_conversa — remove auth.uid() check
DROP FUNCTION IF EXISTS public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_inserir_conversa(
  p_mensagem_id text,
  p_remetente text,
  p_destinatario text,
  p_mensagem text,
  p_cliente_id uuid,
  p_remetente_wa_user_id text,
  p_destinatario_wa_user_id text,
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
  v_user_hash text := private.get_session_phone_hash();
BEGIN
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

  IF p_remetente_wa_user_id IS NULL OR trim(p_remetente_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: remetente_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_destinatario_wa_user_id IS NULL OR trim(p_destinatario_wa_user_id) = '' THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: destinatario_wa_user_id.'
      USING ERRCODE = '23502';
  END IF;

  -- Validar se o id_usuario_wa do remetente ou destinatário corresponde à sessão
  IF private.hash_value(p_remetente_wa_user_id) <> v_user_hash AND private.hash_value(p_destinatario_wa_user_id) <> v_user_hash THEN
    RAISE EXCEPTION 'Usuario fora do contexto da sessao.'
      USING ERRCODE = '42501';
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
    remetente_wa_user_id,
    destinatario_wa_user_id
  ) VALUES (
    p_mensagem_id,
    private.encrypt_value(p_remetente),
    private.encrypt_value(p_destinatario),
    private.encrypt_value(p_mensagem),
    COALESCE(p_cliente_id, v_session_cadastro_id),
    p_remetente_wa_user_id,
    p_destinatario_wa_user_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_inserir_conversa(text, text, text, text, uuid, text, text, text) TO service_role;

-- 5) rpc_selecionar_conversas_por_numero — remove auth.uid() check
DROP FUNCTION IF EXISTS public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_conversas_por_numero(
  p_numero text,
  p_pagina integer DEFAULT 1,
  p_limite integer DEFAULT 100,
  p_sessao_token text DEFAULT NULL,
  p_mensagem_id text DEFAULT NULL
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

  IF p_mensagem_id IS NOT NULL THEN
    RETURN QUERY
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
    WHERE c.mensagem_id = p_mensagem_id
      AND (c.remetente_hash = v_numero_hash OR c.destinatario_hash = v_numero_hash)
    ORDER BY COALESCE(c.horario_mensagem_api, c.horario_mensagem) DESC, c.id DESC;

    RETURN;
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

ALTER FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_conversas_por_numero(text, integer, integer, text, text) TO service_role;

-- 6) rpc_atualizar_cadastro — remove auth.uid() check
DROP FUNCTION IF EXISTS public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_atualizar_cadastro(
  p_id uuid,
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
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_session_wa_hash text;
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  v_session_wa_hash := private.get_session_wa_id_hash();
  IF v_session_wa_hash IS NULL THEN
    RAISE EXCEPTION 'Sessao WhatsApp nao iniciada.'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: id.'
      USING ERRCODE = '23502';
  END IF;

  IF p_tipo IS NOT NULL
     AND NULLIF(btrim(p_tipo), '') IS NOT NULL
     AND btrim(p_tipo) <> 'Pessoa' THEN
    RAISE EXCEPTION 'Parametro invalido: tipo deve ser Pessoa.'
      USING ERRCODE = '22023';
  END IF;

  UPDATE private.cadastro SET
    nome          = COALESCE(p_nome, nome),
    tipo          = 'Pessoa',
    email_enc     = CASE WHEN p_email     IS NOT NULL THEN private.encrypt_value(p_email)     ELSE email_enc END,
    instagram_enc = CASE WHEN p_instagram IS NOT NULL THEN private.encrypt_value(p_instagram) ELSE instagram_enc END,
    linkedin_enc  = CASE WHEN p_linkedin  IS NOT NULL THEN private.encrypt_value(p_linkedin)  ELSE linkedin_enc END,
    empresa       = COALESCE(p_empresa, empresa),
    cargo         = COALESCE(p_cargo, cargo),
    alias_enc         = CASE WHEN p_alias IS NOT NULL AND alias_enc IS NULL THEN private.encrypt_value(p_alias) ELSE alias_enc END,
    id_usuario_wa_enc = CASE WHEN p_id_usuario_wa IS NOT NULL AND id_usuario_wa_enc IS NULL THEN private.encrypt_value(p_id_usuario_wa) ELSE id_usuario_wa_enc END,
    id_usuario_wa_hash = CASE WHEN p_id_usuario_wa IS NOT NULL AND id_usuario_wa_hash IS NULL THEN private.hash_value(p_id_usuario_wa) ELSE id_usuario_wa_hash END,
    updated_at    = NOW()
  WHERE id = p_id
    AND id_usuario_wa_hash = v_session_wa_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: id %', p_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_cadastro(uuid, text, text, text, text, text, text, text, text, text, text) TO service_role;

-- 7) rpc_selecionar_cadastro_por_id — remove auth.uid() check
DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_id(uuid, text);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_id(
  p_id uuid,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE(
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  alias text,
  id_usuario_wa text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token);
  END IF;

  PERFORM private.require_session_wa_id_hash();

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
    private.decrypt_value(c.alias_enc),
    private.decrypt_value(c.id_usuario_wa_enc),
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.id = p_id
    AND c.id_usuario_wa_hash = private.get_session_wa_id_hash();
END;
$$;

ALTER FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_id(uuid, text) TO service_role;

-- 8) rpc_selecionar_cadastro_por_telefone — remove auth.uid() check
DROP FUNCTION IF EXISTS public.rpc_selecionar_cadastro_por_telefone(text, text);
CREATE OR REPLACE FUNCTION public.rpc_selecionar_cadastro_por_telefone(
  p_telefone text,
  p_sessao_token text DEFAULT NULL
) RETURNS TABLE(
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  empresa text,
  cargo text,
  alias text,
  id_usuario_wa text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_hash text := private.hash_phone_number(p_telefone);
BEGIN
  IF p_sessao_token IS NOT NULL THEN
    PERFORM private.activate_session_context(p_sessao_token, p_telefone);
  END IF;

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
    private.decrypt_value(c.alias_enc),
    private.decrypt_value(c.id_usuario_wa_enc),
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE c.telefone_hash = v_hash;
END;
$$;

ALTER FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_selecionar_cadastro_por_telefone(text, text) TO service_role;

-- 9) rpc_atualizar_conversa — remove auth.uid() check (assinatura atual da Fase 1)
DROP FUNCTION IF EXISTS public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_atualizar_conversa(
  p_mensagem_id text,
  p_mensagem text DEFAULT NULL,
  p_cliente_id uuid DEFAULT NULL,
  p_status_mensagem text DEFAULT NULL,
  p_remetente_wa_user_id text DEFAULT NULL,
  p_destinatario_wa_user_id text DEFAULT NULL,
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
    mensagem_enc            = CASE WHEN NULLIF(trim(p_mensagem), '') IS NOT NULL THEN private.encrypt_value(p_mensagem) ELSE mensagem_enc END,
    status_mensagem         = CASE WHEN p_status_mensagem IS NOT NULL THEN p_status_mensagem ELSE status_mensagem END,
    remetente_wa_user_id    = CASE WHEN p_remetente_wa_user_id IS NOT NULL AND remetente_wa_user_id IS NULL THEN p_remetente_wa_user_id ELSE remetente_wa_user_id END,
    destinatario_wa_user_id = CASE WHEN p_destinatario_wa_user_id IS NOT NULL AND destinatario_wa_user_id IS NULL THEN p_destinatario_wa_user_id ELSE destinatario_wa_user_id END
  WHERE mensagem_id = p_mensagem_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Registro nao encontrado: mensagem_id %', p_mensagem_id
      USING ERRCODE = '02000';
  END IF;
END;
$$;

ALTER FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) OWNER TO private_rpc_executor;

REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atualizar_conversa(text, text, uuid, text, text, text, text) TO service_role;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public  FROM private_rpc_executor;
