-- Perfis administrativos usados pelos paineis internos.
-- Usuarios sem perfil nao acessam o painel administrativo.

GRANT CREATE ON SCHEMA public TO private_rpc_executor;
GRANT CREATE ON SCHEMA private TO private_rpc_executor;
-- ---------------------------------------------------------------------------
-- RBAC admin simples.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.admin_perfis (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  codigo text NOT NULL UNIQUE,
  nome text NOT NULL,
  descricao text,
  ativo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_perfis_codigo_check
    CHECK (codigo ~ '^[a-z0-9_]+$'),
  CONSTRAINT admin_perfis_nome_check
    CHECK (btrim(nome) <> '')
);

-- O schema e as tabelas permanecem sob administracao do postgres. A role
-- private_rpc_executor recebe somente os privilegios necessarios para as RPCs.
ALTER TABLE private.admin_perfis OWNER TO postgres;
ALTER TABLE private.admin_perfis ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_admin_perfis_set_updated_at ON private.admin_perfis;
CREATE TRIGGER trg_admin_perfis_set_updated_at
BEFORE UPDATE ON private.admin_perfis
FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at();

CREATE TABLE IF NOT EXISTS private.admin_usuario_perfis (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  auth_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  perfil_id uuid NOT NULL REFERENCES private.admin_perfis (id) ON DELETE CASCADE,
  ativo boolean NOT NULL DEFAULT true,
  concedido_por_auth_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  concedido_em timestamptz NOT NULL DEFAULT now(),
  revogado_em timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_usuario_perfis_revogacao_check
    CHECK ((ativo IS TRUE AND revogado_em IS NULL) OR (ativo IS FALSE))
);

ALTER TABLE private.admin_usuario_perfis OWNER TO postgres;
ALTER TABLE private.admin_usuario_perfis ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS ux_admin_usuario_perfis_ativo
  ON private.admin_usuario_perfis (auth_user_id, perfil_id)
  WHERE ativo IS TRUE AND revogado_em IS NULL;

CREATE INDEX IF NOT EXISTS idx_admin_usuario_perfis_auth_user
  ON private.admin_usuario_perfis (auth_user_id, ativo, revogado_em);

DROP TRIGGER IF EXISTS trg_admin_usuario_perfis_set_updated_at
  ON private.admin_usuario_perfis;
CREATE TRIGGER trg_admin_usuario_perfis_set_updated_at
BEFORE UPDATE ON private.admin_usuario_perfis
FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at();

INSERT INTO private.admin_perfis (codigo, nome, descricao)
VALUES
  ('admin_docs', 'Admin Docs', 'Pode administrar a base publica e a base padrao da Elo.'),
  ('super_admin', 'Super Admin', 'Acesso administrativo total ao produto.')
ON CONFLICT (codigo) DO UPDATE
SET
  nome = EXCLUDED.nome,
  descricao = EXCLUDED.descricao,
  ativo = true;

REVOKE ALL ON TABLE private.admin_perfis FROM PUBLIC;
REVOKE ALL ON TABLE private.admin_perfis FROM anon;
REVOKE ALL ON TABLE private.admin_perfis FROM authenticated;
REVOKE ALL ON TABLE private.admin_perfis FROM service_role;
REVOKE ALL ON TABLE private.admin_perfis FROM private_rpc_executor;

REVOKE ALL ON TABLE private.admin_usuario_perfis FROM PUBLIC;
REVOKE ALL ON TABLE private.admin_usuario_perfis FROM anon;
REVOKE ALL ON TABLE private.admin_usuario_perfis FROM authenticated;
REVOKE ALL ON TABLE private.admin_usuario_perfis FROM service_role;
REVOKE ALL ON TABLE private.admin_usuario_perfis FROM private_rpc_executor;

GRANT SELECT ON TABLE private.admin_perfis TO private_rpc_executor;
GRANT SELECT ON TABLE private.admin_usuario_perfis TO private_rpc_executor;

-- Identidade efetiva usada pela RLS: JWT do usuario ou contexto S2S validado.
CREATE OR REPLACE FUNCTION private.current_admin_subject_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT COALESCE(
    public.request_jwt_sub(),
    CASE
      WHEN current_setting('app.session_s2s_validated', true) = 'true'
      THEN private.get_session_auth_user_id()
      ELSE NULL
    END
  );
$$;

ALTER FUNCTION private.current_admin_subject_id() OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.current_admin_subject_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.current_admin_subject_id() FROM anon;
REVOKE ALL ON FUNCTION private.current_admin_subject_id() FROM authenticated;
REVOKE ALL ON FUNCTION private.current_admin_subject_id() FROM service_role;
GRANT EXECUTE ON FUNCTION private.current_admin_subject_id() TO private_rpc_executor;


CREATE OR REPLACE FUNCTION private.auth_user_has_admin_profile(
  p_auth_user_id uuid,
  p_codigo text
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT
    p_auth_user_id IS NOT NULL
    AND p_auth_user_id = private.current_admin_subject_id()
    AND EXISTS (
      SELECT 1
      FROM private.admin_usuario_perfis aup
      INNER JOIN private.admin_perfis ap ON ap.id = aup.perfil_id
      WHERE aup.auth_user_id = p_auth_user_id
        AND aup.ativo IS TRUE
        AND aup.revogado_em IS NULL
        AND ap.ativo IS TRUE
        AND (
          ap.codigo = p_codigo
          OR (p_codigo <> 'super_admin' AND ap.codigo = 'super_admin')
        )
    );
$$;

ALTER FUNCTION private.auth_user_has_admin_profile(uuid, text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.auth_user_has_admin_profile(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.auth_user_has_admin_profile(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION private.auth_user_has_admin_profile(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.auth_user_has_admin_profile(uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.auth_user_has_admin_profile(uuid, text)
  TO private_rpc_executor;

CREATE OR REPLACE FUNCTION public.request_has_admin_profile(
  p_codigo text
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
  SELECT private.auth_user_has_admin_profile(public.request_jwt_sub(), p_codigo);
$$;

ALTER FUNCTION public.request_has_admin_profile(text)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.request_has_admin_profile(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_has_admin_profile(text) FROM anon;
REVOKE ALL ON FUNCTION public.request_has_admin_profile(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.request_has_admin_profile(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.request_has_admin_profile(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_has_admin_profile(text) TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.validar_admin_profile(
  p_codigo text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
BEGIN
  IF public.request_has_admin_profile(p_codigo) IS NOT TRUE THEN
    RAISE EXCEPTION 'Acesso negado: perfil administrativo requerido (%).', p_codigo
      USING ERRCODE = '42501';
  END IF;
END;
$$;

ALTER FUNCTION private.validar_admin_profile(text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.validar_admin_profile(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.validar_admin_profile(text) FROM anon;
REVOKE ALL ON FUNCTION private.validar_admin_profile(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.validar_admin_profile(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.validar_admin_profile(text) TO private_rpc_executor;

DROP POLICY IF EXISTS admin_perfis_rpc_executor_select ON private.admin_perfis;
DROP POLICY IF EXISTS admin_usuario_perfis_rpc_executor_select ON private.admin_usuario_perfis;
DROP POLICY IF EXISTS admin_perfis_admin_select ON private.admin_perfis;
DROP POLICY IF EXISTS admin_usuario_perfis_admin_select ON private.admin_usuario_perfis;
DROP POLICY IF EXISTS admin_usuario_perfis_super_admin_write ON private.admin_usuario_perfis;
DROP POLICY IF EXISTS admin_usuario_perfis_rpc_executor_insert ON private.admin_usuario_perfis;
DROP POLICY IF EXISTS admin_usuario_perfis_rpc_executor_update ON private.admin_usuario_perfis;

-- Cada usuario enxerga somente os perfis vinculados a ele. A subconsulta
-- tambem respeita a policy de vinculos do proprio usuario.
CREATE POLICY admin_perfis_rpc_executor_select ON private.admin_perfis
  FOR SELECT
  TO private_rpc_executor
  USING (
    EXISTS (
      SELECT 1
      FROM private.admin_usuario_perfis aup
      WHERE aup.perfil_id = admin_perfis.id
        AND aup.auth_user_id = private.current_admin_subject_id()
        AND aup.ativo IS TRUE
        AND aup.revogado_em IS NULL
    )
  );

-- Cada usuario enxerga somente seus proprios vinculos. Nenhuma RPC do fluxo
-- administrativo contorna esta policy.
CREATE POLICY admin_usuario_perfis_rpc_executor_select ON private.admin_usuario_perfis
  FOR SELECT
  TO private_rpc_executor
  USING (auth_user_id = private.current_admin_subject_id());

CREATE OR REPLACE FUNCTION public.rpc_admin_listar_cadastros(
  p_busca text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS TABLE (
  id uuid,
  nome text,
  tipo text,
  telefone text,
  email text,
  empresa text,
  cargo text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_busca text := NULLIF(btrim(p_busca), '');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  PERFORM private.validar_admin_profile('admin_docs');

  RETURN QUERY
  SELECT
    c.id,
    c.nome,
    c.tipo,
    private.decrypt_value(c.telefone_enc),
    private.decrypt_value(c.email_enc),
    c.empresa,
    c.cargo,
    c.status,
    c.created_at,
    c.updated_at
  FROM private.cadastro c
  WHERE v_busca IS NULL
     OR c.nome ILIKE '%' || v_busca || '%'
     OR c.empresa ILIKE '%' || v_busca || '%'
     OR c.cargo ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.telefone_enc) ILIKE '%' || v_busca || '%'
     OR private.decrypt_value(c.email_enc) ILIKE '%' || v_busca || '%'
  ORDER BY c.created_at DESC, c.id
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

ALTER FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer)
  OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) FROM service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_listar_cadastros(text, integer, integer) TO authenticated;
  
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
