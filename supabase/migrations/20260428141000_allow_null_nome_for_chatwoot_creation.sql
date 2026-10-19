-- Permite criação progressiva de cadastro via rpc_identificar_numero
-- sem exigir nome no momento da primeira mensagem.
ALTER TABLE private.cadastro
  ALTER COLUMN nome DROP NOT NULL;
