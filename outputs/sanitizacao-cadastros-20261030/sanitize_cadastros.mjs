import fs from "node:fs/promises";
import { FileBlob, SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const inputPath = "C:/Users/paulo/Downloads/connect - cadastros (2).xlsx";
const outputPath = "./connect-cadastros-sanitizado.xlsx";
const excelEpoch = Date.UTC(1899, 11, 30);

const compact = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
const multiline = (value) => String(value ?? "")
  .replace(/\r\n?/g, "\n")
  .split("\n")
  .map((line) => line.replace(/[ \t]+/g, " ").trim())
  .filter(Boolean)
  .join("\n");
const normalize = (value) => compact(value)
  .normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "")
  .toLocaleLowerCase("pt-BR")
  .replace(/[^a-z0-9]+/g, " ")
  .trim();
const normalizeEmail = (value) => compact(value).toLocaleLowerCase("pt-BR").replace(/\s+/g, "");
const normalizePhone = (value) => {
  let digits = compact(value).replace(/\D/g, "");
  if ((digits.length === 12 || digits.length === 13) && digits.startsWith("55")) digits = digits.slice(2);
  if (digits.length === 12 && digits.startsWith("0")) digits = digits.slice(1);
  return digits;
};
const parseDate = (value) => {
  if (value instanceof Date) return value;
  if (typeof value === "number" && Number.isFinite(value)) return new Date(excelEpoch + value * 86400000);
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
};
const parseYesNo = (value) => {
  const normalized = normalize(value);
  if (normalized.startsWith("sim")) return true;
  if (normalized.startsWith("nao")) return false;
  return null;
};
const unique = (items) => [...new Set(items.filter(Boolean))];
const joinUnique = (items) => unique(items).join("; ");
const truncateWords = (value, maxLength = 100) => {
  const text = compact(value);
  if (text.length <= maxLength) return text;
  const clipped = text.slice(0, maxLength + 1);
  return `${clipped.slice(0, Math.max(clipped.lastIndexOf(" "), maxLength - 20)).trim()}…`;
};

function extractSocial(rawValue) {
  const raw = multiline(rawValue);
  const urls = unique((raw.match(/(?:https?:\/\/|www\.)[^\s,;]+/gi) || [])
    .map((url) => url.replace(/[.)\]}]+$/g, "")));
  const handles = unique(raw.match(/@[A-Za-z0-9._]+/g) || []);
  const instagram = unique([
    ...urls.filter((url) => /instagram\.com/i.test(url)),
    ...handles,
  ]);
  const linkedin = urls.filter((url) => /linkedin\.com/i.test(url));
  const site = urls.filter((url) => !/(instagram|linkedin|facebook|tiktok|wa\.me|whatsapp)\./i.test(url));
  return {
    instagram: joinUnique(instagram),
    linkedin: joinUnique(linkedin),
    site: joinUnique(site),
    original: raw,
  };
}

const genericCategories = new Set([
  "servico", "servicos", "comercio", "saude", "tecnologia", "industria",
  "comercial", "outro", "outros", "profissional liberal", "empreendedorismo",
]);

function deriveServiceName(description, category, company) {
  const desc = multiline(description);
  const categoryClean = compact(category);
  const segments = desc.split(/\n+|(?<=[.!?])\s+/).map(compact).filter(Boolean);
  const servicePattern = /(oferec|atuo com|atuamos com|especializad|servi[cç]os? de|consultoria|assessoria|manuten[cç][aã]o|instala[cç][aã]o|gest[aã]o de|venda de|com[eé]rcio de|produ[cç][aã]o de)/i;
  let candidate = segments.find((segment) => servicePattern.test(segment)) || "";
  candidate = candidate.replace(/^(eu|n[oó]s|a empresa|o neg[oó]cio)\s+/i, "");
  candidate = candidate.replace(/^(ofere[cç]o|oferecemos|atuo com|atuamos com|somos especializados em|[ée] especializada em)\s+/i, "");
  if (candidate) return truncateWords(candidate, 100);
  if (categoryClean && !genericCategories.has(normalize(categoryClean))) return truncateWords(categoryClean, 100);
  const firstPhrase = compact(desc.split(/[,.!?;\n]/)[0]);
  if (firstPhrase) return truncateWords(firstPhrase, 100);
  if (categoryClean) return truncateWords(categoryClean, 100);
  return company ? `Serviço de ${truncateWords(company, 80)}` : "Serviço não informado";
}

function extractProblem(description) {
  const desc = multiline(description);
  const problemPattern = /(problema|falta de|dificuldade|inseguran[cç]a|dor|necessidade|n[aã]o saber|resolv|ajud[oa]|auxili)/i;
  return desc
    .split(/\n+|(?<=[.!?])\s+/)
    .map(compact)
    .filter((segment) => problemPattern.test(segment))
    .slice(0, 3)
    .join(" ");
}

function extractListServices(description) {
  const lines = multiline(description)
    .split("\n")
    .map((line) => compact(line.replace(/^[-–—•*\d.)]+\s*/, "")))
    .filter(Boolean);
  if (lines.length < 2) return [];
  const shortRatio = lines.filter((line) => line.length <= 140).length / lines.length;
  return shortRatio >= 0.7 ? unique(lines) : [];
}

const sourceFile = await FileBlob.load(inputPath);
const sourceWorkbook = await SpreadsheetFile.importXlsx(sourceFile);
const sourceSheet = sourceWorkbook.worksheets.getItemAt(0);
const sourceValues = sourceSheet.getUsedRange(true).values;
const sourceRows = sourceValues.slice(1)
  .map((row, index) => ({ row, rowNumber: index + 2 }))
  .filter(({ row }) => row.some((value) => compact(value) !== ""));

const parent = sourceRows.map((_, index) => index);
const find = (index) => parent[index] === index ? index : (parent[index] = find(parent[index]));
const union = (left, right) => {
  const leftRoot = find(left);
  const rightRoot = find(right);
  if (leftRoot !== rightRoot) parent[rightRoot] = leftRoot;
};
const identityKeys = new Map();

sourceRows.forEach(({ row }, index) => {
  const phone = normalizePhone(row[3]);
  const email = normalizeEmail(row[4]);
  const name = normalize(row[1]);
  const company = normalize(row[5]);
  const keys = [];
  if (phone.length === 10 || phone.length === 11) keys.push(`telefone:${phone}`);
  if (email.includes("@") && name) keys.push(`email_nome:${email}|${name}`);
  if (name && company) keys.push(`nome_empresa:${name}|${company}`);
  for (const key of keys) {
    if (identityKeys.has(key)) union(index, identityKeys.get(key));
    else identityKeys.set(key, index);
  }
});

const groups = new Map();
sourceRows.forEach((entry, index) => {
  const root = find(index);
  if (!groups.has(root)) groups.set(root, []);
  groups.get(root).push(entry);
});

const consolidated = [...groups.values()].map((entries) => {
  const sorted = [...entries].sort((a, b) => {
    const left = parseDate(a.row[0])?.getTime() ?? 0;
    const right = parseDate(b.row[0])?.getTime() ?? 0;
    return left - right || a.rowNumber - b.rowNumber;
  });
  return {
    retained: sorted.at(-1),
    entries: sorted,
  };
}).sort((a, b) => {
  const left = parseDate(a.retained.row[0])?.getTime() ?? 0;
  const right = parseDate(b.retained.row[0])?.getTime() ?? 0;
  return right - left || b.retained.rowNumber - a.retained.rowNumber;
});

const cadastros = consolidated.map(({ retained, entries }, index) => {
  const row = retained.row;
  const key = `ELO-${String(index + 1).padStart(5, "0")}`;
  const date = parseDate(row[0]);
  const name = compact(row[1]);
  const preferredName = compact(row[2]);
  const phone = normalizePhone(row[3]);
  const email = normalizeEmail(row[4]);
  const company = compact(row[5]);
  const description = multiline(row[6]);
  const social = extractSocial(row[7]);
  const category = compact(row[8]);
  const pending = [];
  if (!name) pending.push("Nome ausente");
  if (!(phone.length === 10 || phone.length === 11)) pending.push("Telefone precisa de validação");
  if (!/^\S+@\S+\.\S+$/.test(email)) pending.push("E-mail precisa de validação");
  if (!company) pending.push("Empresa ausente");
  if (!description) pending.push("Descrição do negócio ausente");
  if (!category) pending.push("Setor ausente");
  return {
    key,
    date,
    name,
    preferredName,
    phone,
    email,
    company,
    description,
    category,
    social,
    row,
    retainedRow: retained.rowNumber,
    sourceRows: entries.map((entry) => entry.rowNumber),
    pending,
  };
});

const cadastroHeaders = [
  "chave_importacao_formulario", "cadastro_concluido_em", "nome", "nome_preferido", "tipo",
  "telefone", "email", "instagram", "linkedin", "site", "contatos_publicos_origem",
  "empresa", "cargo", "descricao_negocio", "setor", "cidade", "estado", "status",
  "perfil_ativo", "autoriza_publicacao", "publicar_telefone", "publicar_email",
  "publicar_instagram", "publicar_linkedin", "receber_atualizacoes",
  "tempo_atuacao_empreendedorismo", "interesse_ministerio", "temas_connect",
  "conhecimentos_compartilhar", "disposto_mentor", "igreja_comunidade", "escola_servos",
  "contribuir_palestras_workshops", "impacto_reino", "desafios_empreendedor",
  "origem_connect", "pendencias_validacao", "linha_origem_mantida",
  "linhas_origem_consolidadas", "registros_descartados",
];

const cadastroRows = cadastros.map((item) => [
  item.key, item.date, item.name, item.preferredName, "Pessoa", item.phone, item.email,
  item.social.instagram, item.social.linkedin, item.social.site, item.social.original,
  item.company, compact(item.row[9]), item.description, item.category, "Blumenau", "SC",
  "aprovado", true, false, false, false, false, false, parseYesNo(item.row[21]),
  compact(item.row[10]), multiline(item.row[11]), multiline(item.row[12]), multiline(item.row[13]),
  parseYesNo(item.row[14]), multiline(item.row[15]), compact(item.row[16]), parseYesNo(item.row[17]),
  multiline(item.row[18]), multiline(item.row[19]), multiline(item.row[20]),
  item.pending.join("; "), item.retainedRow, item.sourceRows.join(", "), item.sourceRows.length - 1,
]);

const rawServices = [];
for (const item of cadastros) {
  const listItems = extractListServices(item.description);
  const descriptions = listItems.length ? listItems : [item.description];
  for (const serviceDescription of descriptions) {
    const serviceName = deriveServiceName(serviceDescription || item.description, item.category, item.company);
    const pending = [];
    if (!item.company) pending.push("Empresa ausente");
    if (!serviceDescription) pending.push("Descrição do serviço ausente");
    if (!item.category) pending.push("Categoria ausente");
    if (genericCategories.has(normalize(item.category))) pending.push("Categoria genérica; revisar");
    rawServices.push({
      key: item.key,
      date: item.date,
      company: item.company || item.name,
      serviceName,
      description: serviceDescription,
      problems: extractProblem(item.description),
      specialties: listItems.length > 1 ? joinUnique(listItems) : "",
      category: item.category,
      contacts: item.social.original,
      pending: pending.join("; "),
      sourceRow: item.retainedRow,
    });
  }
}

const serviceMap = new Map();
for (const service of rawServices) {
  const dedupeKey = `${normalize(service.company)}|${normalize(service.serviceName)}|${normalize(service.description)}`;
  const previous = serviceMap.get(dedupeKey);
  if (!previous || (service.date?.getTime() ?? 0) > (previous.date?.getTime() ?? 0)) {
    serviceMap.set(dedupeKey, service);
  }
}
const services = [...serviceMap.values()].sort((a, b) => {
  const companyOrder = a.company.localeCompare(b.company, "pt-BR", { sensitivity: "base" });
  return companyOrder || a.serviceName.localeCompare(b.serviceName, "pt-BR", { sensitivity: "base" });
});

const serviceHeaders = [
  "chave_importacao_formulario", "empresa", "nome_servico", "descricao",
  "problemas_resolvidos", "especialidades", "categoria_nome", "categoria_aliases",
  "cidade", "estado", "contatos_redes_sociais", "ativo", "publicado",
  "status_indexacao", "origem_carga", "pendencias_validacao", "linha_origem",
];
const serviceRows = services.map((item) => [
  item.key, item.company, item.serviceName, item.description, item.problems, item.specialties,
  item.category, "", "Blumenau", "SC", item.contacts, true, false, "pendente",
  "formulario_connect_sanitizado", item.pending, item.sourceRow,
]);

const workbook = Workbook.create();
const cadastroSheet = workbook.worksheets.add("Cadastros");
const serviceSheet = workbook.worksheets.add("Serviços");

function writeStructuredSheet(sheet, headers, rows, tableName, columnWidths, wrapColumns) {
  sheet.showGridLines = false;
  const matrix = [headers, ...rows];
  const range = sheet.getRangeByIndexes(0, 0, matrix.length, headers.length);
  range.values = matrix;
  range.format.font = { name: "Arial", size: 10, color: "#17231E" };
  range.format.verticalAlignment = "center";
  const header = sheet.getRangeByIndexes(0, 0, 1, headers.length);
  header.format = {
    fill: "#075A46",
    font: { name: "Arial", size: 10, bold: true, color: "#FFFFFF" },
    horizontalAlignment: "center",
    verticalAlignment: "center",
    wrapText: true,
    borders: { preset: "inside", style: "thin", color: "#DDE9E4" },
  };
  header.format.rowHeight = 34;
  for (const [column, width] of Object.entries(columnWidths)) {
    sheet.getRange(`${column}1:${column}${matrix.length}`).format.columnWidth = width;
  }
  for (const column of wrapColumns) {
    const wrapped = sheet.getRange(`${column}2:${column}${matrix.length}`);
    wrapped.format.wrapText = true;
    wrapped.format.verticalAlignment = "top";
  }
  const table = sheet.tables.add(range.address, true, tableName);
  table.style = "TableStyleMedium4";
  table.showFilterButton = true;
  table.showBandedColumns = false;
  sheet.freezePanes.freezeRows(1);
  sheet.freezePanes.freezeColumns(2);
  if (matrix.length > 1) sheet.getRange(`A2:${String.fromCharCode(64 + Math.min(headers.length, 26))}${matrix.length}`).format.rowHeight = 24;
}

writeStructuredSheet(
  cadastroSheet,
  cadastroHeaders,
  cadastroRows,
  "CadastrosSanitizados",
  {
    A: 21, B: 20, C: 28, D: 22, E: 12, F: 16, G: 30, H: 28, I: 28, J: 28,
    K: 38, L: 32, M: 22, N: 55, O: 25, P: 16, Q: 10, R: 14, S: 12, T: 18,
    U: 16, V: 16, W: 18, X: 18, Y: 20, Z: 24, AA: 34, AB: 34, AC: 34,
    AD: 18, AE: 34, AF: 20, AG: 22, AH: 48, AI: 48, AJ: 28, AK: 35,
    AL: 20, AM: 30, AN: 20,
  },
  ["K", "N", "AA", "AB", "AC", "AE", "AH", "AI", "AJ", "AK"],
);
cadastroSheet.getRange(`B2:B${cadastroRows.length + 1}`).setNumberFormat("dd/mm/yyyy hh:mm");
cadastroSheet.getRange(`F2:F${cadastroRows.length + 1}`).setNumberFormat("@");
cadastroSheet.getRange(`G2:G${cadastroRows.length + 1}`).setNumberFormat("@");

writeStructuredSheet(
  serviceSheet,
  serviceHeaders,
  serviceRows,
  "ServicosSanitizados",
  {
    A: 21, B: 34, C: 38, D: 60, E: 48, F: 48, G: 25, H: 30, I: 16,
    J: 10, K: 42, L: 12, M: 12, N: 18, O: 30, P: 38, Q: 16,
  },
  ["C", "D", "E", "F", "K", "P"],
);

workbook.recalculate();

const cadastroCheck = await workbook.inspect({
  kind: "table",
  range: `Cadastros!A1:N12`,
  include: "values,formulas",
  tableMaxRows: 12,
  tableMaxCols: 14,
  maxChars: 12000,
});
const serviceCheck = await workbook.inspect({
  kind: "table",
  range: `Serviços!A1:Q12`,
  include: "values,formulas",
  tableMaxRows: 12,
  tableMaxCols: 17,
  maxChars: 14000,
});
const formulaErrors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!",
  options: { useRegex: true, maxResults: 300 },
  summary: "final formula error scan",
});

console.log("--- CADASTROS ---");
console.log(cadastroCheck.ndjson);
console.log("--- SERVIÇOS ---");
console.log(serviceCheck.ndjson);
console.log("--- ERROS DE FÓRMULA ---");
console.log(formulaErrors.ndjson);

const cadastroPreview = await workbook.render({
  sheetName: "Cadastros",
  range: "A1:N18",
  scale: 1.2,
  format: "png",
});
const servicePreview = await workbook.render({
  sheetName: "Serviços",
  range: "A1:Q18",
  scale: 1.2,
  format: "png",
});
await fs.writeFile("./cadastros-preview.png", new Uint8Array(await cadastroPreview.arrayBuffer()));
await fs.writeFile("./servicos-preview.png", new Uint8Array(await servicePreview.arrayBuffer()));

const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);

const verificationFile = await FileBlob.load(outputPath);
const verifiedWorkbook = await SpreadsheetFile.importXlsx(verificationFile);
const verification = await verifiedWorkbook.inspect({
  kind: "workbook,sheet,table",
  maxChars: 6000,
  tableMaxRows: 3,
  tableMaxCols: 8,
});
console.log("--- VERIFICAÇÃO DO ARQUIVO EXPORTADO ---");
console.log(verification.ndjson);
console.log(JSON.stringify({
  sourceRecords: sourceRows.length,
  uniqueCadastros: cadastroRows.length,
  removedDuplicates: sourceRows.length - cadastroRows.length,
  duplicateGroups: [...groups.values()].filter((group) => group.length > 1).length,
  serviceRows: serviceRows.length,
  cadastrosWithPendingReview: cadastros.filter((item) => item.pending.length > 0).length,
  servicesWithPendingReview: services.filter((item) => item.pending).length,
  outputPath,
}, null, 2));
