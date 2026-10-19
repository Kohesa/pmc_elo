-- Corrige "permission denied for function _crypto_aead_det_decrypt" ao inserir
-- documento na base de conhecimento.
--
-- O acesso ao Vault passa por vault.decrypted_secrets, que usa pgsodium internamente.
-- private_rpc_executor nao tem acesso direto ao pgsodium.
--
-- Solucao: OWNER TO postgres na funcao de leitura do Vault, seguindo o mesmo
-- limite criptografico de private.get_encryption_key() (20260402110000).
--
-- Superficie de risco minima:
--   - GUC guard: so executa se app.n8n_base_conhecimento_config_allowed = 'true'
--     (setado pelo trigger com is_local=true — some ao fim da transacao)
--   - GRANT EXECUTE somente para private_rpc_executor
--   - Funcao le apenas dois segredos especificos do Vault, sem escrita nem rede
--   - notificar_n8n_processar_base_conhecimento() permanece OWNER TO private_rpc_executor

GRANT CREATE ON SCHEMA private TO private_rpc_executor;

CREATE OR REPLACE FUNCTION private.get_n8n_base_conhecimento_webhook_config()
RETURNS TABLE (
  webhook_url text,
  auth_header text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'vault'
AS $$
DECLARE
  v_webhook_url text;
  v_auth_header text;
BEGIN
  IF current_setting('app.n8n_base_conhecimento_config_allowed', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Acesso negado: configuracao do webhook deve ser lida somente pelo trigger da base de conhecimento.'
      USING ERRCODE = '42501';
  END IF;

  SELECT ds.decrypted_secret
    INTO v_webhook_url
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'n8n_base_conhecimento_webhook_url'
  LIMIT 1;

  SELECT ds.decrypted_secret
    INTO v_auth_header
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'n8n_base_conhecimento_auth'
  LIMIT 1;

  webhook_url := NULLIF(btrim(v_webhook_url), '');
  auth_header := NULLIF(btrim(v_auth_header), '');

  IF webhook_url IS NULL THEN
    RAISE EXCEPTION 'Webhook n8n nao configurado: segredo n8n_base_conhecimento_webhook_url ausente.'
      USING ERRCODE = '22023';
  END IF;

  IF auth_header IS NULL THEN
    RAISE EXCEPTION 'Webhook n8n nao configurado: segredo n8n_base_conhecimento_auth ausente.'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEXT;
END;
$$;

ALTER FUNCTION private.get_n8n_base_conhecimento_webhook_config()
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.get_n8n_base_conhecimento_webhook_config() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.get_n8n_base_conhecimento_webhook_config() FROM anon;
REVOKE ALL ON FUNCTION private.get_n8n_base_conhecimento_webhook_config() FROM authenticated;
REVOKE ALL ON FUNCTION private.get_n8n_base_conhecimento_webhook_config() FROM service_role;
GRANT EXECUTE ON FUNCTION private.get_n8n_base_conhecimento_webhook_config()
  TO private_rpc_executor;

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
