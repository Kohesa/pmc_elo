import fs from "node:fs/promises";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const workbookPath = "./connect-cadastros-sanitizado.xlsx";
const sqlPath = "./importar-cadastros-servicos-elo.sql";
const excelEpoch = Date.UTC(1899, 11, 30);

const compact = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
const nullable = (value) => {
  const text = compact(value);
  return text === "" ? null : text;
};
const bool = (value) => value === true || String(value).toLowerCase() === "true";
const normalize = (value) => compact(value)
  .normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "")
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, " ")
  .trim();
const isoDate = (value) => {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(excelEpoch + value * 86400000).toISOString();
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
};
const splitList = (value) => [...new Set(String(value ?? "")
  .split(/;|\n/)
  .map(compact)
  .filter(Boolean))];

const source = await SpreadsheetFile.importXlsx(await FileBlob.load(workbookPath));

function readSheet(name) {
  const sheet = source.worksheets.getItem(name);
  const values = sheet.getUsedRange(true).values;
  const headers = values[0].map((value) => compact(value));
  return values.slice(1)
    .filter((row) => row.some((value) => compact(value) !== ""))
    .map((row) => Object.fromEntries(headers.map((header, index) => [header, row[index]])));
}

const cadastroSource = readSheet("Cadastros");
const serviceSource = readSheet("Serviços");

const cadastros = cadastroSource.map((row) => ({
  chave_importacao_formulario: compact(row.chave_importacao_formulario),
  cadastro_concluido_em: isoDate(row.cadastro_concluido_em),
  nome: nullable(row.nome),
  nome_preferido: nullable(row.nome_preferido),
  tipo: nullable(row.tipo) || "Pessoa",
  telefone: nullable(row.telefone),
  email: nullable(row.email)?.toLowerCase() ?? null,
  instagram: nullable(row.instagram),
  linkedin: nullable(row.linkedin),
  site: nullable(row.site),
  empresa: nullable(row.empresa),
  cargo: nullable(row.cargo),
  descricao_negocio: nullable(row.descricao_negocio),
  setor: nullable(row.setor),
  cidade: nullable(row.cidade) || "Blumenau",
  estado: nullable(row.estado) || "SC",
  status: nullable(row.status) || "aprovado",
  perfil_ativo: bool(row.perfil_ativo),
  receber_atualizacoes: bool(row.receber_atualizacoes),
  respostas_formulario: {
    tempo_atuacao_empreendedorismo: nullable(row.tempo_atuacao_empreendedorismo),
    interesse_ministerio: nullable(row.interesse_ministerio),
    temas_connect: nullable(row.temas_connect),
    conhecimentos_compartilhar: nullable(row.conhecimentos_compartilhar),
    disposto_mentor: row.disposto_mentor === null || row.disposto_mentor === "" ? null : bool(row.disposto_mentor),
    igreja_comunidade: nullable(row.igreja_comunidade),
    escola_servos: nullable(row.escola_servos),
    contribuir_palestras_workshops: row.contribuir_palestras_workshops === null || row.contribuir_palestras_workshops === "" ? null : bool(row.contribuir_palestras_workshops),
    impacto_reino: nullable(row.impacto_reino),
    desafios_empreendedor: nullable(row.desafios_empreendedor),
    origem_connect: nullable(row.origem_connect),
    contatos_publicos_origem: nullable(row.contatos_publicos_origem),
    pendencias_validacao: nullable(row.pendencias_validacao),
    linha_origem_mantida: row.linha_origem_mantida ?? null,
    linhas_origem_consolidadas: nullable(row.linhas_origem_consolidadas),
    registros_descartados: row.registros_descartados ?? 0,
  },
}));

if (cadastros.some((row) => !row.chave_importacao_formulario || !row.nome)) {
  throw new Error("Há cadastro sem chave de importação ou nome.");
}

const serviceMap = new Map();
for (const row of serviceSource) {
  const key = compact(row.chave_importacao_formulario);
  const name = nullable(row.nome_servico);
  if (!key || !name) continue;

  const description = nullable(row.descricao) || name;
  const service = {
    chave_importacao_formulario: key,
    nome: name,
    descricao: description,
    problemas_resolvidos: nullable(row.problemas_resolvidos),
    especialidades: splitList(row.especialidades),
    categoria_nome: nullable(row.categoria_nome) || "Não informado",
    categoria_aliases: splitList(row.categoria_aliases),
    cidade: nullable(row.cidade) || "Blumenau",
    estado: nullable(row.estado) || "SC",
    origem_carga: nullable(row.origem_carga) || "formulario_connect_sanitizado",
    _descriptions: [description],
    _problems: nullable(row.problemas_resolvidos) ? [compact(row.problemas_resolvidos)] : [],
  };

  const mapKey = `${key}|${normalize(name)}`;
  const current = serviceMap.get(mapKey);
  if (!current) {
    serviceMap.set(mapKey, service);
  } else {
    current._descriptions = [...new Set([...current._descriptions, ...service._descriptions])];
    current._problems = [...new Set([...current._problems, ...service._problems])];
    current.especialidades = [...new Set([...current.especialidades, ...service.especialidades])];
    current.categoria_aliases = [...new Set([...current.categoria_aliases, ...service.categoria_aliases])];
    current.descricao = current._descriptions.join("\n");
    current.problemas_resolvidos = current._problems.join("\n") || null;
  }
}
const services = [...serviceMap.values()].map(({ _descriptions, _problems, ...service }) => service);

const knownKeys = new Set(cadastros.map((row) => row.chave_importacao_formulario));
const orphanServices = services.filter((row) => !knownKeys.has(row.chave_importacao_formulario));
if (orphanServices.length) throw new Error(`Há ${orphanServices.length} serviços sem cadastro correspondente.`);

const cadastroJson = JSON.stringify(cadastros);
const serviceJson = JSON.stringify(services);
const cadastroDelimiter = "$elo_cadastros_20261030$";
const serviceDelimiter = "$elo_servicos_20261030$";
if (cadastroJson.includes(cadastroDelimiter) || serviceJson.includes(serviceDelimiter)) {
  throw new Error("Delimitador SQL encontrado no conteúdo.");
}

const sql = `-- Carga administrativa sanitizada da Elo Connect
-- Gerado a partir da planilha validada em 2026-10-30.
-- Execute somente no SQL Editor do Supabase ou via psql como owner do banco.
-- Não exponha este arquivo em endpoint, REST ou RPC: ele contém dados pessoais.
-- Pré-requisitos: migrations até 20261017211500 aplicadas e secret encryption_key no Vault.
-- A carga é idempotente pela chave_importacao_formulario.
-- Privacidade por padrão: perfis e serviços entram sem autorização/publicação.

BEGIN;

SELECT set_config('app.session_importacao_empresarios', 'true', true);

DO $preflight$
BEGIN
  IF to_regclass('private.cadastro') IS NULL
     OR to_regclass('private.cadastro_servicos') IS NULL THEN
    RAISE EXCEPTION 'Estrutura da Elo não encontrada. Aplique as migrations antes da carga.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'private'
      AND table_name = 'cadastro'
      AND column_name = 'chave_importacao_formulario'
  ) THEN
    RAISE EXCEPTION 'Migration 20261017211500_private_spreadsheet_cadastro_import.sql não aplicada.';
  END IF;
END
$preflight$;

CREATE TEMP TABLE _elo_cadastros_import ON COMMIT DROP AS
SELECT *
FROM jsonb_to_recordset(${cadastroDelimiter}${cadastroJson}${cadastroDelimiter}::jsonb) AS x(
  chave_importacao_formulario text,
  cadastro_concluido_em timestamptz,
  nome text,
  nome_preferido text,
  tipo text,
  telefone text,
  email text,
  instagram text,
  linkedin text,
  site text,
  empresa text,
  cargo text,
  descricao_negocio text,
  setor text,
  cidade text,
  estado text,
  status text,
  perfil_ativo boolean,
  receber_atualizacoes boolean,
  respostas_formulario jsonb
);

CREATE UNIQUE INDEX ON _elo_cadastros_import (chave_importacao_formulario);

INSERT INTO private.cadastro AS cadastro (
  chave_importacao_formulario,
  nome,
  nome_preferido,
  tipo,
  telefone_enc,
  telefone_hash,
  email_enc,
  instagram_enc,
  linkedin_enc,
  empresa,
  cargo,
  descricao_negocio,
  setor,
  cidade,
  estado,
  site,
  status,
  perfil_ativo,
  cadastro_concluido_em,
  autoriza_publicacao,
  autoriza_publicacao_em,
  publicar_telefone,
  publicar_email,
  publicar_instagram,
  publicar_linkedin,
  respostas_formulario_enc,
  receber_atualizacoes,
  receber_atualizacoes_em,
  termos_uso_aceito,
  politica_privacidade_aceita,
  created_at,
  updated_at
)
SELECT
  c.chave_importacao_formulario,
  NULLIF(btrim(c.nome), ''),
  NULLIF(btrim(c.nome_preferido), ''),
  COALESCE(NULLIF(btrim(c.tipo), ''), 'Pessoa'),
  CASE WHEN NULLIF(btrim(c.telefone), '') IS NULL THEN NULL
       ELSE private.encrypt_value(btrim(c.telefone)) END,
  CASE WHEN NULLIF(btrim(c.telefone), '') IS NULL THEN NULL
       ELSE private.hash_value(btrim(c.telefone)) END,
  CASE WHEN NULLIF(btrim(c.email), '') IS NULL THEN NULL
       ELSE private.encrypt_value(lower(btrim(c.email))) END,
  CASE WHEN NULLIF(btrim(c.instagram), '') IS NULL THEN NULL
       ELSE private.encrypt_value(btrim(c.instagram)) END,
  CASE WHEN NULLIF(btrim(c.linkedin), '') IS NULL THEN NULL
       ELSE private.encrypt_value(btrim(c.linkedin)) END,
  NULLIF(btrim(c.empresa), ''),
  NULLIF(btrim(c.cargo), ''),
  NULLIF(btrim(c.descricao_negocio), ''),
  NULLIF(btrim(c.setor), ''),
  COALESCE(NULLIF(btrim(c.cidade), ''), 'Blumenau'),
  upper(COALESCE(NULLIF(btrim(c.estado), ''), 'SC')),
  NULLIF(btrim(c.site), ''),
  'aprovado',
  COALESCE(c.perfil_ativo, true),
  COALESCE(c.cadastro_concluido_em, now()),
  false,
  NULL,
  false,
  false,
  false,
  false,
  private.encrypt_value(COALESCE(c.respostas_formulario, '{}'::jsonb)::text),
  COALESCE(c.receber_atualizacoes, false),
  CASE WHEN COALESCE(c.receber_atualizacoes, false)
       THEN COALESCE(c.cadastro_concluido_em, now()) ELSE NULL END,
  false,
  false,
  COALESCE(c.cadastro_concluido_em, now()),
  now()
FROM _elo_cadastros_import c
ON CONFLICT (chave_importacao_formulario)
  WHERE chave_importacao_formulario IS NOT NULL
DO UPDATE SET
  nome = EXCLUDED.nome,
  nome_preferido = EXCLUDED.nome_preferido,
  tipo = EXCLUDED.tipo,
  telefone_enc = EXCLUDED.telefone_enc,
  telefone_hash = EXCLUDED.telefone_hash,
  email_enc = EXCLUDED.email_enc,
  instagram_enc = EXCLUDED.instagram_enc,
  linkedin_enc = EXCLUDED.linkedin_enc,
  empresa = EXCLUDED.empresa,
  cargo = EXCLUDED.cargo,
  descricao_negocio = EXCLUDED.descricao_negocio,
  setor = EXCLUDED.setor,
  cidade = EXCLUDED.cidade,
  estado = EXCLUDED.estado,
  site = EXCLUDED.site,
  status = EXCLUDED.status,
  perfil_ativo = EXCLUDED.perfil_ativo,
  cadastro_concluido_em = EXCLUDED.cadastro_concluido_em,
  respostas_formulario_enc = EXCLUDED.respostas_formulario_enc,
  receber_atualizacoes = EXCLUDED.receber_atualizacoes,
  receber_atualizacoes_em = EXCLUDED.receber_atualizacoes_em,
  updated_at = now();

CREATE TEMP TABLE _elo_servicos_import ON COMMIT DROP AS
SELECT *
FROM jsonb_to_recordset(${serviceDelimiter}${serviceJson}${serviceDelimiter}::jsonb) AS x(
  chave_importacao_formulario text,
  nome text,
  descricao text,
  problemas_resolvidos text,
  especialidades text[],
  categoria_nome text,
  categoria_aliases text[],
  cidade text,
  estado text,
  origem_carga text
);

CREATE UNIQUE INDEX ON _elo_servicos_import (
  chave_importacao_formulario,
  lower(btrim(nome))
);

INSERT INTO private.cadastro_servicos AS servico (
  cadastro_id,
  nome,
  descricao,
  problemas_resolvidos,
  especialidades,
  categoria_nome,
  categoria_aliases,
  cidade,
  estado,
  descricao_busca,
  status_indexacao,
  embedding,
  embedding_model,
  indexed_at,
  erro_indexacao,
  ativo,
  publicado,
  publicado_em,
  origem_carga,
  created_at,
  updated_at
)
SELECT
  c.id,
  btrim(s.nome),
  COALESCE(NULLIF(btrim(s.descricao), ''), btrim(s.nome)),
  NULLIF(btrim(s.problemas_resolvidos), ''),
  COALESCE(s.especialidades, '{}'::text[]),
  COALESCE(NULLIF(btrim(s.categoria_nome), ''), 'Não informado'),
  COALESCE(s.categoria_aliases, '{}'::text[]),
  COALESCE(NULLIF(btrim(s.cidade), ''), 'Blumenau'),
  upper(COALESCE(NULLIF(btrim(s.estado), ''), 'SC')),
  concat_ws(E'\\n',
    'Empresa: ' || COALESCE(c.empresa, c.nome),
    'Serviço: ' || btrim(s.nome),
    'Categoria informada: ' || COALESCE(NULLIF(btrim(s.categoria_nome), ''), 'Não informado'),
    'Descrição: ' || COALESCE(NULLIF(btrim(s.descricao), ''), btrim(s.nome)),
    CASE WHEN NULLIF(btrim(s.problemas_resolvidos), '') IS NOT NULL
      THEN 'Problemas atendidos: ' || btrim(s.problemas_resolvidos) END,
    CASE WHEN cardinality(COALESCE(s.especialidades, '{}'::text[])) > 0
      THEN 'Especialidades: ' || array_to_string(s.especialidades, ', ') END,
    CASE WHEN cardinality(COALESCE(s.categoria_aliases, '{}'::text[])) > 0
      THEN 'Termos informados: ' || array_to_string(s.categoria_aliases, ', ') END
  ),
  'pendente',
  NULL,
  NULL,
  NULL,
  NULL,
  true,
  false,
  NULL,
  COALESCE(NULLIF(btrim(s.origem_carga), ''), 'formulario_connect_sanitizado'),
  COALESCE(c.cadastro_concluido_em, now()),
  now()
FROM _elo_servicos_import s
INNER JOIN private.cadastro c
  ON c.chave_importacao_formulario = s.chave_importacao_formulario
ON CONFLICT (cadastro_id, (lower(btrim(nome))))
DO UPDATE SET
  descricao = EXCLUDED.descricao,
  problemas_resolvidos = EXCLUDED.problemas_resolvidos,
  especialidades = EXCLUDED.especialidades,
  categoria_nome = EXCLUDED.categoria_nome,
  categoria_aliases = EXCLUDED.categoria_aliases,
  cidade = EXCLUDED.cidade,
  estado = EXCLUDED.estado,
  descricao_busca = EXCLUDED.descricao_busca,
  embedding = NULL,
  embedding_model = NULL,
  indexed_at = NULL,
  erro_indexacao = NULL,
  status_indexacao = 'pendente',
  ativo = true,
  origem_carga = EXCLUDED.origem_carga,
  updated_at = now();

DO $validation$
DECLARE
  v_cadastros_esperados integer := ${cadastros.length};
  v_servicos_esperados integer := ${services.length};
  v_cadastros_encontrados integer;
  v_servicos_encontrados integer;
BEGIN
  SELECT count(*) INTO v_cadastros_encontrados
  FROM private.cadastro c
  INNER JOIN _elo_cadastros_import i
    ON i.chave_importacao_formulario = c.chave_importacao_formulario;

  SELECT count(*) INTO v_servicos_encontrados
  FROM private.cadastro_servicos cs
  INNER JOIN private.cadastro c ON c.id = cs.cadastro_id
  INNER JOIN _elo_servicos_import i
    ON i.chave_importacao_formulario = c.chave_importacao_formulario
   AND lower(btrim(i.nome)) = lower(btrim(cs.nome));

  IF v_cadastros_encontrados <> v_cadastros_esperados THEN
    RAISE EXCEPTION 'Validação falhou: esperados % cadastros, encontrados %.',
      v_cadastros_esperados, v_cadastros_encontrados;
  END IF;
  IF v_servicos_encontrados <> v_servicos_esperados THEN
    RAISE EXCEPTION 'Validação falhou: esperados % serviços, encontrados %.',
      v_servicos_esperados, v_servicos_encontrados;
  END IF;

  RAISE NOTICE 'Carga validada: % cadastros e % serviços.',
    v_cadastros_encontrados, v_servicos_encontrados;
END
$validation$;

COMMIT;

SELECT
  count(*) AS cadastros_importados,
  count(*) FILTER (WHERE autoriza_publicacao) AS cadastros_autorizados_publicacao,
  count(*) FILTER (WHERE NOT autoriza_publicacao) AS cadastros_aguardando_consentimento
FROM private.cadastro
WHERE chave_importacao_formulario LIKE 'ELO-%';

SELECT
  count(*) AS servicos_importados,
  count(*) FILTER (WHERE publicado) AS servicos_publicados,
  count(*) FILTER (WHERE status_indexacao = 'pendente') AS servicos_pendentes_indexacao
FROM private.cadastro_servicos
WHERE origem_carga = 'formulario_connect_sanitizado';
`;

await fs.writeFile(sqlPath, sql, "utf8");
console.log(JSON.stringify({
  sqlPath,
  cadastros: cadastros.length,
  servicosPlanilha: serviceSource.length,
  servicosSql: services.length,
  servicosMescladosPorNome: serviceSource.length - services.length,
  bytes: Buffer.byteLength(sql, "utf8"),
}, null, 2));
