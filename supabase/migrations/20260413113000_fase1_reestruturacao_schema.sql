-- Estrutura operacional compartilhada pela Elo: cadastro, identidade de canal,
-- consumo de IA e vinculo interno dos documentos processados.

ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS auth_user_id uuid,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'aprovado',
  ADD COLUMN IF NOT EXISTS whatsapp_user_id text,
  ADD COLUMN IF NOT EXISTS whatsapp_user_id_hash text,
  ADD COLUMN IF NOT EXISTS whatsapp_alias text;

ALTER TABLE private.cadastro
  DROP CONSTRAINT IF EXISTS check_status,
  DROP CONSTRAINT IF EXISTS check_tipo,
  DROP CONSTRAINT IF EXISTS cadastro_status_check;

UPDATE private.cadastro
SET
  tipo = 'Pessoa',
  status = CASE WHEN status = 'bloqueado' THEN 'bloqueado' ELSE 'aprovado' END;

ALTER TABLE private.cadastro
  ALTER COLUMN tipo SET DEFAULT 'Pessoa',
  ALTER COLUMN status SET DEFAULT 'aprovado',
  ADD CONSTRAINT cadastro_status_check CHECK (status IN ('aprovado', 'bloqueado')),
  DROP CONSTRAINT IF EXISTS cadastro_auth_user_id_fkey,
  ADD CONSTRAINT cadastro_auth_user_id_fkey
    FOREIGN KEY (auth_user_id) REFERENCES auth.users (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_cadastro_auth_user_id
  ON private.cadastro (auth_user_id)
  WHERE auth_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cadastro_whatsapp_user_id_hash
  ON private.cadastro (whatsapp_user_id_hash)
  WHERE whatsapp_user_id_hash IS NOT NULL;

CREATE OR REPLACE FUNCTION private.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'private', 'public'
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cadastro_set_updated_at ON private.cadastro;
CREATE TRIGGER trg_cadastro_set_updated_at
BEFORE UPDATE ON private.cadastro
FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at();


CREATE OR REPLACE FUNCTION private.get_session_wa_id_hash()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
  SELECT NULLIF(current_setting('app.session_wa_id_hash', true), '');
$$;

CREATE TABLE IF NOT EXISTS private.uso_tokens (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  cadastro_id uuid NOT NULL REFERENCES private.cadastro (id) ON DELETE CASCADE,
  wa_id_hash text NOT NULL,
  telefone_hash text,
  mensagem_id text NOT NULL,
  tokens_consumidos numeric NOT NULL DEFAULT 0 CHECK (tokens_consumidos >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uso_tokens_cadastro_mensagem_key UNIQUE (cadastro_id, mensagem_id)
);

CREATE INDEX IF NOT EXISTS idx_uso_tokens_cadastro_created_at
  ON private.uso_tokens (cadastro_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_uso_tokens_wa_id_hash_created_at
  ON private.uso_tokens (wa_id_hash, created_at DESC);

ALTER TABLE private.uso_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS uso_tokens_select ON private.uso_tokens;
CREATE POLICY uso_tokens_select ON private.uso_tokens
  FOR SELECT
  USING (
    private.get_session_wa_id_hash() IS NOT NULL
    AND wa_id_hash = private.get_session_wa_id_hash()
  );
DROP POLICY IF EXISTS uso_tokens_insert ON private.uso_tokens;
CREATE POLICY uso_tokens_insert ON private.uso_tokens
  FOR INSERT
  WITH CHECK (private.get_session_wa_id_hash() IS NOT NULL);
GRANT SELECT, INSERT ON TABLE private.uso_tokens TO private_rpc_executor;

ALTER TABLE private.base_conhecimento
  ADD COLUMN IF NOT EXISTS cadastro_id uuid;

ALTER TABLE private.base_conhecimento
  DROP CONSTRAINT IF EXISTS base_conhecimento_cadastro_id_fkey,
  ADD CONSTRAINT base_conhecimento_cadastro_id_fkey
    FOREIGN KEY (cadastro_id) REFERENCES private.cadastro (id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_base_conhecimento_cadastro_hora_criacao
  ON private.base_conhecimento (cadastro_id, hora_criacao DESC, id DESC);

ALTER TABLE private.conversas
  ADD COLUMN IF NOT EXISTS remetente_wa_user_id text,
  ADD COLUMN IF NOT EXISTS destinatario_wa_user_id text;
