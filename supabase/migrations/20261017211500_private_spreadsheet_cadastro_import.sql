ALTER TABLE private.cadastro
  ADD COLUMN IF NOT EXISTS chave_importacao_formulario text,
  ADD COLUMN IF NOT EXISTS respostas_formulario_enc text,
  ADD COLUMN IF NOT EXISTS receber_atualizacoes boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS receber_atualizacoes_em timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS ux_cadastro_chave_importacao_formulario
  ON private.cadastro (chave_importacao_formulario)
  WHERE chave_importacao_formulario IS NOT NULL;
