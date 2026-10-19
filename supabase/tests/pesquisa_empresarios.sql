\set ON_ERROR_STOP on

BEGIN;

INSERT INTO private.credenciais_s2s (client_id, client_secret_hash, ativo)
VALUES (
  'teste-pesquisa-empresarios',
  extensions.crypt('segredo-teste-pesquisa', extensions.gen_salt('bf')),
  true
)
ON CONFLICT (client_id) DO UPDATE
SET client_secret_hash = excluded.client_secret_hash,
    ativo = true,
    updated_at = now();

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'processar_base_conhecimento'
) AS token_processar \gset

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'processar_base_conhecimento'
) AS token_processar_eletricista \gset

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'set_contexto'
) AS token_contexto \gset

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'buscar_contexto_ia'
) AS token_busca \gset

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'buscar_contexto_ia'
) AS token_busca_bloqueado \gset

SELECT public.rpc_autenticar_s2s(
  'teste-pesquisa-empresarios',
  'segredo-teste-pesquisa',
  'buscar_contexto_ia'
) AS token_busca_eletricista \gset

SET LOCAL ROLE service_role;

SELECT cadastro_id, servico_id, documento_id
FROM public.rpc_importar_servico_empresario_s2s(
  p_token_s2s => :'token_processar',
  p_nome => 'Empresario Teste',
  p_empresa => 'Assistencia Teste',
  p_categoria => 'Assistencia tecnica de eletrodomesticos',
  p_servico => 'Conserto de maquinas de lavar',
  p_descricao => 'Diagnostico e conserto de maquinas de lavar roupas.',
  p_autoriza_publicacao => true,
  p_problemas_resolvidos => 'Maquina nao liga, nao centrifuga ou apresenta vazamento.',
  p_especialidades => ARRAY['maquina de lavar', 'lavadora'],
  p_categoria_aliases => ARRAY['mecanica', 'conserto de eletrodomesticos'],
  p_cidade => 'Blumenau',
  p_estado => 'SC',
  p_telefone => '47999999999',
  p_publicar_telefone => false,
  p_created_at => '2020-01-01T12:00:00Z'::timestamptz
) \gset empresa_

SELECT cadastro_id, servico_id, documento_id
FROM public.rpc_importar_servico_empresario_s2s(
  p_token_s2s => :'token_processar_eletricista',
  p_nome => 'Eletricista Teste',
  p_empresa => 'Eletrica Residencial Teste',
  p_categoria => 'Eletrica e automacao residencial',
  p_servico => 'Instalacoes eletricas residenciais',
  p_descricao => 'Instalacoes e manutencoes eletricas em residencias.',
  p_autoriza_publicacao => true,
  p_problemas_resolvidos => 'Instalacao eletrica e manutencao residencial.',
  p_especialidades => ARRAY['instalacoes eletricas', 'manutencao eletrica'],
  p_categoria_aliases => ARRAY['eletrica', 'eletricista'],
  p_cidade => 'Blumenau',
  p_estado => 'SC',
  p_created_at => '2019-01-01T12:00:00Z'::timestamptz
) \gset eletricista_

SELECT public.rpc_set_contexto_sessao(
  :'token_contexto',
  'chatwoot_teste_pesquisa',
  NULL
) AS sessao_token \gset

SELECT set_config('test.sessao_token', :'sessao_token', false);
SELECT set_config('test.token_busca', :'token_busca', false);
SELECT set_config('test.token_busca_bloqueado', :'token_busca_bloqueado', false);
SELECT set_config('test.token_busca_eletricista', :'token_busca_eletricista', false);

RESET ROLE;

UPDATE private.base_conhecimento
SET status_indexacao = 'indexado',
    indexado_em = now(),
    qtd_chunks = 1,
    embedding_model = 'teste'
WHERE id = :'empresa_documento_id'::uuid;

UPDATE private.base_conhecimento
SET status_indexacao = 'indexado',
    indexado_em = now(),
    qtd_chunks = 1,
    embedding_model = 'teste'
WHERE id = :'eletricista_documento_id'::uuid;

INSERT INTO private.base_conhecimento_chunks (
  base_conhecimento_id,
  cadastro_id,
  categoria_id,
  chunk_index,
  conteudo,
  conteudo_hash,
  embedding,
  embedding_model,
  token_count
)
SELECT
  bc.id,
  bc.cadastro_id,
  bc.area_empresa,
  0,
  private.encrypt_value('Conserto de maquinas de lavar roupas e lavadoras.'),
  encode(extensions.digest('chunk-teste', 'sha256'), 'hex'),
  ('[' || array_to_string(array_fill(0::double precision, ARRAY[384]), ',') || ']')::extensions.vector(384),
  'teste',
  10
FROM private.base_conhecimento bc
WHERE bc.id = :'empresa_documento_id'::uuid;

INSERT INTO private.base_conhecimento_chunks (
  base_conhecimento_id, cadastro_id, categoria_id, chunk_index, conteudo,
  conteudo_hash, embedding, embedding_model, token_count
)
SELECT
  bc.id, bc.cadastro_id, bc.area_empresa, 0,
  private.encrypt_value('Instalacoes e manutencoes eletricas residenciais.'),
  encode(extensions.digest('chunk-eletricista-teste', 'sha256'), 'hex'),
  ('[' || array_to_string(array_fill(0::double precision, ARRAY[384]), ',') || ']')::extensions.vector(384),
  'teste', 10
FROM private.base_conhecimento bc
WHERE bc.id = :'eletricista_documento_id'::uuid;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_total integer;
  v_telefone text;
BEGIN
  SELECT count(*), max(r.telefone)
    INTO v_total, v_telefone
  FROM public.rpc_buscar_empresarios_s2s(
    p_wa_user_id => 'chatwoot_teste_pesquisa',
    p_consulta => 'preciso consertar minha maquina de lavar',
    p_categoria => 'mecanica',
    p_score_min => 0.50,
    p_sessao_token => current_setting('test.sessao_token'),
    p_token_s2s => current_setting('test.token_busca_bloqueado')
  ) r
  WHERE r.empresa = 'Assistencia Teste';

  IF v_total <> 1 THEN
    RAISE EXCEPTION 'Esperado um empresario publicado, recebido %.', v_total;
  END IF;
  IF v_telefone IS NOT NULL THEN
    RAISE EXCEPTION 'Telefone sem autorizacao foi exposto.';
  END IF;
END;
$$;

DO $$
DECLARE
  v_total integer;
  v_empresa text;
  v_score double precision;
BEGIN
  SELECT count(*), max(r.empresa), max(r.score)
    INTO v_total, v_empresa, v_score
  FROM public.rpc_buscar_empresarios_s2s(
    p_wa_user_id => 'chatwoot_teste_pesquisa',
    p_consulta => 'eletricista instalar chuveiro',
    p_cidade => 'Joinville',
    p_estado => 'PR',
    p_score_min => 0.50,
    p_sessao_token => current_setting('test.sessao_token'),
    p_token_s2s => current_setting('test.token_busca_eletricista')
  ) r
  WHERE r.empresa = 'Eletrica Residencial Teste';

  IF v_total <> 1 OR v_empresa <> 'Eletrica Residencial Teste' THEN
    RAISE EXCEPTION 'Pesquisa eletrica sem filtro de localidade falhou: total %, empresa %.', v_total, v_empresa;
  END IF;
  IF v_score < 0.50 THEN
    RAISE EXCEPTION 'Resultado eletrico abaixo do corte minimo: %.', v_score;
  END IF;
END;
$$;

RESET ROLE;

UPDATE private.cadastro
SET status = 'bloqueado'
WHERE id = :'empresa_cadastro_id'::uuid;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_total integer;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.rpc_buscar_empresarios_s2s(
    p_wa_user_id => 'chatwoot_teste_pesquisa',
    p_consulta => 'maquina de lavar',
    p_categoria => 'mecanica',
    p_score_min => 0.50,
    p_sessao_token => current_setting('test.sessao_token'),
    p_token_s2s => current_setting('test.token_busca')
  ) r
  WHERE r.empresa = 'Assistencia Teste';

  IF v_total <> 0 THEN
    RAISE EXCEPTION 'Cadastro bloqueado apareceu na pesquisa.';
  END IF;
END;
$$;

RESET ROLE;
ROLLBACK;

SELECT 'pesquisa_empresarios_ok' AS resultado;
