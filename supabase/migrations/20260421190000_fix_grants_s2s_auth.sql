-- Hotfix: grants necessários para rpc_autenticar_s2s e validar_token_s2s funcionarem.
--
-- Causa raiz: private.credenciais_s2s foi criada em 20260413114000 sem GRANT para
-- private_rpc_executor, fazendo rpc_autenticar_s2s retornar "permission denied for table
-- credenciais_s2s" ao tentar verificar as credenciais S2S.
--
-- Grants de extensão são defensivos: em algumas configurações do Supabase as funções do
-- pgcrypto não são PUBLIC, e rpc_autenticar_s2s / validar_token_s2s as chamam diretamente.

-- 1. Tabela de credenciais S2S — leitura necessária para validar client_id + client_secret
GRANT SELECT ON TABLE private.credenciais_s2s TO private_rpc_executor;

-- 2. Funções pgcrypto usadas em rpc_autenticar_s2s
--    extensions.hmac       → gera o HMAC do payload (defesa em profundidade)
--    extensions.digest     → fallback SHA-256 para client_secrets legados
--    extensions.crypt      → comparação bcrypt para client_secrets novos
--    extensions.gen_salt   → geração de salt bcrypt (necessário ao recadastrar secrets)
--    extensions.gen_random_bytes → gera o nonce de 128 bits

GRANT EXECUTE ON FUNCTION extensions.hmac(text, text, text)    TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.hmac(bytea, bytea, text)  TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.digest(text, text)        TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text)       TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.crypt(text, text)         TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.gen_salt(text)            TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.gen_salt(text, integer)   TO private_rpc_executor;
GRANT EXECUTE ON FUNCTION extensions.gen_random_bytes(integer) TO private_rpc_executor;
