-- Separa a identidade privada do participante da ficha publica da empresa.
-- private.cadastro continua sendo a identidade privada da pessoa que usa a Elo.
-- private.empresas passa a ser a fonte oficial dos dados comerciais publicaveis.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE TABLE IF NOT EXISTS private.empresas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cadastro_responsavel_id uuid REFERENCES private.cadastro(id) ON DELETE SET NULL,
  nome text NOT NULL,
  descricao_negocio text,
  setor text,
  cidade text,
  estado text,
  telefone_publico text,
  email_publico text,
  links_publicos jsonb NOT NULL DEFAULT '[]'::jsonb,
  ativo boolean NOT NULL DEFAULT true,
  publicado boolean NOT NULL DEFAULT false,
  autorizado_publicacao_em timestamptz,
  publicacao_termo_versao text,
  origem_carga text NOT NULL DEFAULT 'elo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT empresas_nome_obrigatorio CHECK (btrim(nome) <> ''),
  CONSTRAINT empresas_estado_valido CHECK (estado IS NULL OR estado ~ '^[A-Z]{2}$'),
  CONSTRAINT empresas_links_publicos_array CHECK (jsonb_typeof(links_publicos) = 'array'),
  CONSTRAINT empresas_publicacao_autorizada CHECK (
    publicado = false OR autorizado_publicacao_em IS NOT NULL
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS empresas_responsavel_nome_uniq
  ON private.empresas (cadastro_responsavel_id, lower(btrim(nome)))
  WHERE cadastro_responsavel_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS empresas_publicadas_idx
  ON private.empresas (publicado, ativo, created_at, id)
  WHERE publicado = true AND ativo = true;

CREATE INDEX IF NOT EXISTS empresas_responsavel_idx
  ON private.empresas (cadastro_responsavel_id);

ALTER TABLE private.empresas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS empresas_select_pesquisa_s2s ON private.empresas;
CREATE POLICY empresas_select_pesquisa_s2s
ON private.empresas
FOR SELECT
TO private_rpc_executor
USING (
  current_setting('app.session_pesquisa_empresarios', true) = 'true'
  AND ativo = true
  AND publicado = true
  AND autorizado_publicacao_em IS NOT NULL
);

DROP POLICY IF EXISTS empresas_select_importacao_s2s ON private.empresas;
CREATE POLICY empresas_select_importacao_s2s
ON private.empresas
FOR SELECT
TO private_rpc_executor
USING (current_setting('app.session_importacao_planilha', true) = 'true');

DROP POLICY IF EXISTS empresas_insert_importacao_s2s ON private.empresas;
CREATE POLICY empresas_insert_importacao_s2s
ON private.empresas
FOR INSERT
TO private_rpc_executor
WITH CHECK (current_setting('app.session_importacao_planilha', true) = 'true');

DROP POLICY IF EXISTS empresas_update_importacao_s2s ON private.empresas;
CREATE POLICY empresas_update_importacao_s2s
ON private.empresas
FOR UPDATE
TO private_rpc_executor
USING (current_setting('app.session_importacao_planilha', true) = 'true')
WITH CHECK (current_setting('app.session_importacao_planilha', true) = 'true');

DROP POLICY IF EXISTS empresas_select_admin ON private.empresas;
CREATE POLICY empresas_select_admin
ON private.empresas
FOR SELECT
TO private_rpc_executor
USING (current_setting('app.session_admin_operacao', true) = 'true');

DROP POLICY IF EXISTS empresas_update_responsavel ON private.empresas;
CREATE POLICY empresas_update_responsavel
ON private.empresas
FOR UPDATE
TO private_rpc_executor
USING (
  EXISTS (
    SELECT 1
      FROM private.cadastro c
     WHERE c.id = empresas.cadastro_responsavel_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
      FROM private.cadastro c
     WHERE c.id = empresas.cadastro_responsavel_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
);

CREATE OR REPLACE FUNCTION private.normalizar_links_publicos(
  p_site text DEFAULT NULL,
  p_instagram text DEFAULT NULL,
  p_linkedin text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'pg_catalog', 'private'
AS $$
DECLARE
  v_fontes text[] := ARRAY[p_site, p_instagram, p_linkedin];
  v_fonte text;
  v_parte text;
  v_url text;
  v_tipo text;
  v_rotulo text;
  v_indice integer := 0;
  v_links jsonb := '[]'::jsonb;
  v_vistos text[] := ARRAY[]::text[];
BEGIN
  FOREACH v_fonte IN ARRAY v_fontes LOOP
    v_indice := v_indice + 1;
    IF NULLIF(btrim(v_fonte), '') IS NULL THEN
      CONTINUE;
    END IF;

    FOREACH v_parte IN ARRAY regexp_split_to_array(btrim(v_fonte), E'[\\s;,]+') LOOP
      v_parte := btrim(v_parte, '[](){}<>"''');
      IF v_parte = '' THEN
        CONTINUE;
      END IF;

      IF v_parte LIKE '@%' AND v_indice = 2 THEN
        v_url := 'https://www.instagram.com/' || ltrim(v_parte, '@');
      ELSIF v_parte ~* '^https?://' THEN
        v_url := v_parte;
      ELSIF v_parte ~* '^www\\.' THEN
        v_url := 'https://' || v_parte;
      ELSIF v_parte ~* '^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}(/.*)?$' THEN
        v_url := 'https://' || v_parte;
      ELSE
        CONTINUE;
      END IF;

      v_url := regexp_replace(v_url, '[.]+$', '');
      IF lower(v_url) = ANY(v_vistos) THEN
        CONTINUE;
      END IF;
      v_vistos := array_append(v_vistos, lower(v_url));

      v_tipo := CASE
        WHEN v_url ~* 'instagram\\.com' THEN 'instagram'
        WHEN v_url ~* 'linkedin\\.com' THEN 'linkedin'
        WHEN v_url ~* 'youtube\\.com|youtu\\.be' THEN 'youtube'
        WHEN v_url ~* 'facebook\\.com|fb\\.com' THEN 'facebook'
        WHEN v_url ~* 'tiktok\\.com' THEN 'tiktok'
        WHEN v_url ~* 'linktr\\.ee|linktree\\.' THEN 'linktree'
        ELSE 'site'
      END;
      v_rotulo := CASE v_tipo
        WHEN 'instagram' THEN 'Instagram'
        WHEN 'linkedin' THEN 'LinkedIn'
        WHEN 'youtube' THEN 'YouTube'
        WHEN 'facebook' THEN 'Facebook'
        WHEN 'tiktok' THEN 'TikTok'
        WHEN 'linktree' THEN 'Linktree'
        ELSE 'Site'
      END;

      v_links := v_links || jsonb_build_array(
        jsonb_build_object('tipo', v_tipo, 'rotulo', v_rotulo, 'url', v_url)
      );
    END LOOP;
  END LOOP;

  RETURN v_links;
END;
$$;

ALTER FUNCTION private.normalizar_links_publicos(text, text, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.normalizar_links_publicos(text, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- Migra uma ficha publica por cadastro que ja possui servico.
INSERT INTO private.empresas (
  cadastro_responsavel_id,
  nome,
  descricao_negocio,
  setor,
  cidade,
  estado,
  telefone_publico,
  email_publico,
  links_publicos,
  ativo,
  publicado,
  autorizado_publicacao_em,
  publicacao_termo_versao,
  origem_carga,
  created_at,
  updated_at
)
SELECT
  c.id,
  COALESCE(NULLIF(btrim(c.empresa), ''), NULLIF(btrim(c.nome_preferido), ''), NULLIF(btrim(c.nome), ''), 'Empresa sem nome'),
  NULLIF(btrim(c.descricao_negocio), ''),
  NULLIF(btrim(c.setor), ''),
  NULLIF(btrim(c.cidade), ''),
  CASE WHEN c.estado IS NULL THEN NULL ELSE upper(btrim(c.estado)) END,
  CASE
    WHEN c.publicar_telefone OR EXISTS (
      SELECT 1
        FROM private.cadastro_servicos cs_planilha
       WHERE cs_planilha.cadastro_id = c.id
         AND cs_planilha.origem_carga IN ('controlada', 'formulario_connect_sanitizado')
    ) THEN private.decrypt_value(c.telefone_enc)
  END,
  CASE
    WHEN c.publicar_email OR EXISTS (
      SELECT 1
        FROM private.cadastro_servicos cs_planilha
       WHERE cs_planilha.cadastro_id = c.id
         AND cs_planilha.origem_carga IN ('controlada', 'formulario_connect_sanitizado')
    ) THEN private.decrypt_value(c.email_enc)
  END,
  private.normalizar_links_publicos(
    c.site,
    CASE WHEN c.publicar_instagram THEN private.decrypt_value(c.instagram_enc) END,
    CASE WHEN c.publicar_linkedin THEN private.decrypt_value(c.linkedin_enc) END
  ),
  c.perfil_ativo,
  (
    c.status = 'aprovado'
    AND c.perfil_ativo
    AND c.cadastro_concluido_em IS NOT NULL
    AND c.autoriza_publicacao
    AND c.autoriza_publicacao_em IS NOT NULL
  ),
  c.autoriza_publicacao_em,
  c.publicacao_termo_versao,
  'migracao_cadastro_legado',
  c.created_at,
  c.updated_at
FROM private.cadastro c
WHERE EXISTS (
  SELECT 1 FROM private.cadastro_servicos cs WHERE cs.cadastro_id = c.id
)
ON CONFLICT (cadastro_responsavel_id, lower(btrim(nome)))
WHERE cadastro_responsavel_id IS NOT NULL
DO UPDATE SET
  descricao_negocio = EXCLUDED.descricao_negocio,
  setor = EXCLUDED.setor,
  cidade = EXCLUDED.cidade,
  estado = EXCLUDED.estado,
  telefone_publico = EXCLUDED.telefone_publico,
  email_publico = EXCLUDED.email_publico,
  links_publicos = EXCLUDED.links_publicos,
  ativo = EXCLUDED.ativo,
  publicado = EXCLUDED.publicado,
  autorizado_publicacao_em = EXCLUDED.autorizado_publicacao_em,
  publicacao_termo_versao = EXCLUDED.publicacao_termo_versao,
  updated_at = now();

ALTER TABLE private.cadastro_servicos
  ADD COLUMN IF NOT EXISTS empresa_id uuid REFERENCES private.empresas(id) ON DELETE CASCADE;

UPDATE private.cadastro_servicos cs
   SET empresa_id = e.id
  FROM private.empresas e
 WHERE cs.empresa_id IS NULL
   AND e.cadastro_responsavel_id = cs.cadastro_id;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM private.cadastro_servicos WHERE empresa_id IS NULL) THEN
    RAISE EXCEPTION 'Existem servicos sem empresa publica vinculada; a migracao foi interrompida.';
  END IF;
END;
$$;

ALTER TABLE private.cadastro_servicos
  ALTER COLUMN empresa_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS cadastro_servicos_empresa_idx
  ON private.cadastro_servicos (empresa_id, ativo, publicado, created_at);

DROP INDEX IF EXISTS private.cadastro_servicos_nome_uniq;
CREATE UNIQUE INDEX IF NOT EXISTS cadastro_servicos_empresa_nome_uniq
  ON private.cadastro_servicos (empresa_id, lower(btrim(nome)));

DROP POLICY IF EXISTS cadastro_servicos_select_publicado_s2s ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_select_publicado_s2s
ON private.cadastro_servicos
FOR SELECT
TO private_rpc_executor
USING (
  current_setting('app.session_pesquisa_empresarios', true) = 'true'
  AND ativo = true
  AND publicado = true
  AND EXISTS (
    SELECT 1
      FROM private.empresas e
     WHERE e.id = cadastro_servicos.empresa_id
       AND e.ativo = true
       AND e.publicado = true
       AND e.autorizado_publicacao_em IS NOT NULL
  )
);

DROP POLICY IF EXISTS cadastro_servicos_select_responsavel ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_select_responsavel
ON private.cadastro_servicos
FOR SELECT
TO private_rpc_executor
USING (
  EXISTS (
    SELECT 1
      FROM private.empresas e
      JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
     WHERE e.id = cadastro_servicos.empresa_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
);

DROP POLICY IF EXISTS cadastro_servicos_update_responsavel ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_update_responsavel
ON private.cadastro_servicos
FOR UPDATE
TO private_rpc_executor
USING (
  EXISTS (
    SELECT 1
      FROM private.empresas e
      JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
     WHERE e.id = cadastro_servicos.empresa_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
      FROM private.empresas e
      JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
     WHERE e.id = cadastro_servicos.empresa_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
);

COMMENT ON TABLE private.empresas IS 'Ficha comercial publicavel. E a unica origem permitida para dados de empresa enviados ao RAG/IA.';
COMMENT ON TABLE private.cadastro IS 'Identidade privada da pessoa/contato. Nao deve ser projetada para prompts ou respostas da IA.';
COMMENT ON COLUMN private.empresas.links_publicos IS 'Array de objetos {tipo, rotulo, url}; permite novas redes sem alterar o schema.';
COMMENT ON COLUMN private.cadastro_servicos.empresa_id IS 'Empresa publica proprietaria do servico; substitui o vinculo direto do servico com cadastro.';

GRANT SELECT, INSERT, UPDATE ON TABLE private.empresas TO private_rpc_executor;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.cadastro_servicos TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
