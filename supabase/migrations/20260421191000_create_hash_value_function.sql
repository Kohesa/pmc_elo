-- Cria private.hash_value(text): função genérica de hash SHA-256 para valores não-telefone
-- (ex: id_usuario_wa). Análoga a private.hash_phone_number mas sem normalização de telefone,
-- pois o wa_id já chega no formato canônico da Meta.

CREATE OR REPLACE FUNCTION private.hash_value(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
  SELECT encode(extensions.digest(p_value, 'sha256'), 'hex');
$$;

REVOKE ALL ON FUNCTION private.hash_value(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.hash_value(text) FROM anon;
REVOKE ALL ON FUNCTION private.hash_value(text) FROM authenticated;
REVOKE ALL ON FUNCTION private.hash_value(text) FROM service_role;
GRANT EXECUTE ON FUNCTION private.hash_value(text) TO private_rpc_executor;
