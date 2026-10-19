-- Registra os aceites legais vinculados ao cadastro da Elo.
-- Os campos ficam disponíveis para o fluxo de cadastro conversacional.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;
GRANT CREATE ON SCHEMA public  TO private_rpc_executor;

ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS termos_uso_aceito boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS termos_uso_aceito_em timestamptz,
  ADD COLUMN IF NOT EXISTS politica_privacidade_aceita boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS politica_privacidade_aceita_em timestamptz,
  ADD COLUMN IF NOT EXISTS documentos_legais_versao text;

ALTER TABLE private.cadastro
  DROP CONSTRAINT IF EXISTS cadastro_termos_uso_aceito_em_check;

ALTER TABLE private.cadastro
  ADD CONSTRAINT cadastro_termos_uso_aceito_em_check
  CHECK (termos_uso_aceito IS FALSE OR termos_uso_aceito_em IS NOT NULL);

ALTER TABLE private.cadastro
  DROP CONSTRAINT IF EXISTS cadastro_politica_privacidade_aceita_em_check;

ALTER TABLE private.cadastro
  ADD CONSTRAINT cadastro_politica_privacidade_aceita_em_check
  CHECK (politica_privacidade_aceita IS FALSE OR politica_privacidade_aceita_em IS NOT NULL);

COMMENT ON COLUMN private.cadastro.termos_uso_aceito IS 'Indica se a pessoa aceitou os Termos de Uso no cadastro.';
COMMENT ON COLUMN private.cadastro.termos_uso_aceito_em IS 'Data e hora do aceite dos Termos de Uso.';
COMMENT ON COLUMN private.cadastro.politica_privacidade_aceita IS 'Indica se a pessoa aceitou a Politica de Privacidade no cadastro.';
COMMENT ON COLUMN private.cadastro.politica_privacidade_aceita_em IS 'Data e hora do aceite da Politica de Privacidade.';
COMMENT ON COLUMN private.cadastro.documentos_legais_versao IS 'Versao dos documentos legais aceitos pela pessoa.';
