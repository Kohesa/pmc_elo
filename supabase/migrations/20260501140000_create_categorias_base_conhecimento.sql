-- Categorias e armazenamento da base de conhecimento padrão da Elo.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public TO private_rpc_executor;

CREATE TABLE IF NOT EXISTS private.categorias (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  cadastro_id uuid,
  nome text NOT NULL CHECK (btrim(nome) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_categorias_public_nome
  ON private.categorias (nome)
  WHERE cadastro_id IS NULL;

DROP TRIGGER IF EXISTS trg_categorias_set_updated_at ON private.categorias;
CREATE TRIGGER trg_categorias_set_updated_at
BEFORE UPDATE ON private.categorias
FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

ALTER TABLE private.categorias ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE private.categorias TO private_rpc_executor;

INSERT INTO private.categorias (cadastro_id, nome)
SELECT DISTINCT NULL::uuid, COALESCE(NULLIF(btrim(bc.area_empresa), ''), 'Sem categoria')
FROM private.base_conhecimento bc
ON CONFLICT (nome) WHERE cadastro_id IS NULL DO NOTHING;

ALTER TABLE private.base_conhecimento
  ADD COLUMN IF NOT EXISTS area_empresa_categoria_id uuid;

UPDATE private.base_conhecimento bc
SET area_empresa_categoria_id = c.id
FROM private.categorias c
WHERE c.cadastro_id IS NULL
  AND c.nome = COALESCE(NULLIF(btrim(bc.area_empresa), ''), 'Sem categoria');

ALTER TABLE private.base_conhecimento
  ALTER COLUMN area_empresa_categoria_id SET NOT NULL;
ALTER TABLE private.base_conhecimento RENAME COLUMN area_empresa TO area_empresa_nome_migrado;
ALTER TABLE private.base_conhecimento RENAME COLUMN area_empresa_categoria_id TO area_empresa;
ALTER TABLE private.base_conhecimento
  ADD CONSTRAINT base_conhecimento_area_empresa_fkey
  FOREIGN KEY (area_empresa) REFERENCES private.categorias (id) ON DELETE CASCADE;
ALTER TABLE private.base_conhecimento DROP COLUMN area_empresa_nome_migrado;

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_area_empresa_hora_criacao
  ON private.base_conhecimento (area_empresa, hora_criacao DESC, id DESC);

CREATE OR REPLACE FUNCTION private.get_or_create_categoria_base_conhecimento(
  p_cadastro_id uuid,
  p_nome text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
SET row_security TO 'on'
AS $$
DECLARE
  v_nome text := NULLIF(btrim(p_nome), '');
  v_categoria_id uuid;
BEGIN
  IF v_nome IS NULL THEN
    RAISE EXCEPTION 'Campo obrigatorio ausente: tema.' USING ERRCODE = '23502';
  END IF;
  IF p_cadastro_id IS NOT NULL THEN
    RAISE EXCEPTION 'A Elo aceita somente categorias da base padrao.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO private.categorias (cadastro_id, nome)
  VALUES (NULL, v_nome)
  ON CONFLICT (nome) WHERE cadastro_id IS NULL DO UPDATE SET nome = EXCLUDED.nome
  RETURNING id INTO v_categoria_id;
  RETURN v_categoria_id;
END;
$$;

ALTER FUNCTION private.get_or_create_categoria_base_conhecimento(uuid, text) OWNER TO private_rpc_executor;
REVOKE ALL ON FUNCTION private.get_or_create_categoria_base_conhecimento(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.get_or_create_categoria_base_conhecimento(uuid, text) TO private_rpc_executor;

ALTER TABLE private.base_conhecimento
  ADD COLUMN IF NOT EXISTS status_processamento text NOT NULL DEFAULT 'processando',
  ADD COLUMN IF NOT EXISTS url_documento text;

UPDATE private.base_conhecimento SET status_processamento = 'processado';
ALTER TABLE private.base_conhecimento
  DROP CONSTRAINT IF EXISTS base_conhecimento_status_processamento_check,
  ADD CONSTRAINT base_conhecimento_status_processamento_check
    CHECK (status_processamento IN ('processando', 'processado', 'erro')),
  ALTER COLUMN documento DROP NOT NULL,
  DROP CONSTRAINT IF EXISTS base_conhecimento_url_documento_not_blank_check,
  ADD CONSTRAINT base_conhecimento_url_documento_not_blank_check
    CHECK (url_documento IS NULL OR btrim(url_documento) <> '');

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_status_processamento
  ON private.base_conhecimento (status_processamento);

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'base-conhecimento-documentos',
  'base-conhecimento-documentos',
  false,
  5242880,
  ARRAY['application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

GRANT USAGE ON SCHEMA storage TO private_rpc_executor;
GRANT SELECT ON TABLE storage.objects TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
REVOKE CREATE ON SCHEMA public FROM private_rpc_executor;
