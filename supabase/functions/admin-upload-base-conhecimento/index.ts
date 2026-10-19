import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET_NAME = "base-conhecimento-documentos";
const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_FILES_PER_UPLOAD = 10;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type UploadedDocument = {
  id: unknown;
  bucket: string;
  path: string;
  url_documento: string;
  status_processamento: "processando";
  tamanho_bytes: number;
  nome: string;
};

type UploadFailure = {
  nome: string;
  error: string;
  stage: string;
};

function getErrorMessage(error: unknown, fallback: string) {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "object" && error && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message.trim()) return message;
  }
  return fallback;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function errorResponse(stage: string, error: unknown, status = 400) {
  return jsonResponse({
    error: getErrorMessage(error, "Nao foi possivel concluir o upload."),
    stage,
  }, status);
}

function sanitizeFileName(name: string) {
  const fallback = "documento.pdf";
  const baseName = (name || fallback)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9._-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .toLowerCase();

  const safeName = baseName || fallback;
  return safeName.endsWith(".pdf") ? safeName : `${safeName}.pdf`;
}

function storageObjectUrl(supabaseUrl: string, path: string) {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  return `${supabaseUrl}/storage/v1/object/${BUCKET_NAME}/${encodedPath}`;
}

function normalizeScope(value: FormDataEntryValue | null) {
  const scope = String(value || "").trim().toLowerCase();
  if (scope !== "publico" && scope !== "default_elo") return "";
  return scope;
}

Deno.serve(async (req) => {
  try {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    if (req.method !== "POST") {
      return jsonResponse({ error: "Metodo nao permitido.", stage: "method" }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const authHeader = req.headers.get("Authorization");

    if (!supabaseUrl || !supabaseAnonKey) {
      return jsonResponse({ error: "Variaveis SUPABASE_URL ou SUPABASE_ANON_KEY ausentes.", stage: "env" }, 500);
    }

    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Authorization header Bearer obrigatorio.", stage: "auth_header" }, 401);
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
      auth: {
        persistSession: false,
      },
    });

    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) {
      return errorResponse("auth_user", userError || "Usuario nao autenticado.", 401);
    }

    let formData: FormData;
    try {
      formData = await req.formData();
    } catch {
      return jsonResponse({ error: "Envie multipart/form-data com file, escopo e categoria_id.", stage: "form_data" }, 400);
    }

    const files = [
      ...formData.getAll("file"),
      ...formData.getAll("files"),
    ].filter((entry): entry is File => entry instanceof File);
    const escopo = normalizeScope(formData.get("escopo"));
    const categoriaId = String(formData.get("categoria_id") || "").trim();
    const tipoRelatorioRaw = String(formData.get("tipo_relatorio") || "").trim();
    const tipoRelatorio = tipoRelatorioRaw || null;

    if (!escopo) {
      return jsonResponse({ error: "Campo escopo invalido.", stage: "validation" }, 400);
    }

    if (!categoriaId) {
      return jsonResponse({ error: "Campo obrigatorio ausente: categoria_id.", stage: "validation" }, 400);
    }

    if (files.length === 0) {
      return jsonResponse({ error: "Campo obrigatorio ausente: file.", stage: "validation" }, 400);
    }

    if (files.length > MAX_FILES_PER_UPLOAD) {
      return jsonResponse({ error: `Envie no maximo ${MAX_FILES_PER_UPLOAD} documentos por upload.`, stage: "validation" }, 413);
    }

    const invalidType = files.find((file) => {
      const isPdfMime = file.type === "application/pdf";
      const isPdfName = file.name.toLowerCase().endsWith(".pdf");
      return !isPdfMime && !isPdfName;
    });
    if (invalidType) {
      return jsonResponse({ error: `Formato invalido em ${invalidType.name}: envie somente PDF.`, stage: "validation" }, 415);
    }

    const empty = files.find((file) => file.size <= 0);
    if (empty) {
      return jsonResponse({ error: `Arquivo vazio: ${empty.name}.`, stage: "validation" }, 400);
    }

    const oversized = files.find((file) => file.size > MAX_FILE_BYTES);
    if (oversized) {
      return jsonResponse({ error: `Arquivo ${oversized.name} excede o limite de 5MB.`, stage: "validation" }, 413);
    }

    const uploadedDocuments: UploadedDocument[] = [];
    const failures: UploadFailure[] = [];

    for (const file of files) {
      const safeName = sanitizeFileName(file.name);
      const objectPath = `_system/${escopo}/${crypto.randomUUID()}-${safeName}`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET_NAME)
        .upload(objectPath, file, {
          contentType: "application/pdf",
          cacheControl: "3600",
          upsert: false,
        });

      if (uploadError) {
        failures.push({
          nome: file.name,
          error: getErrorMessage(uploadError, "Nao foi possivel enviar o arquivo."),
          stage: "storage_upload",
        });
        continue;
      }

      const urlDocumento = storageObjectUrl(supabaseUrl, objectPath);
      const { data: documentId, error: insertError } = await supabase.rpc(
        "rpc_admin_kb_inserir_upload_documento",
        {
          p_escopo: escopo,
          p_categoria_id: categoriaId,
          p_url_documento: urlDocumento,
          p_tamanho_bytes: file.size,
          p_tipo_relatorio: tipoRelatorio,
        },
      );

      if (insertError) {
        const { error: removeError } = await supabase.storage
          .from(BUCKET_NAME)
          .remove([objectPath]);
        if (removeError) {
          console.error("admin-upload-base-conhecimento rollback falhou", { objectPath, removeError });
        }
        failures.push({
          nome: file.name,
          error: getErrorMessage(insertError, "Nao foi possivel registrar o documento."),
          stage: "rpc_insert",
        });
        continue;
      }

      uploadedDocuments.push({
        id: documentId,
        bucket: BUCKET_NAME,
        path: objectPath,
        url_documento: urlDocumento,
        status_processamento: "processando",
        tamanho_bytes: file.size,
        nome: file.name,
      });
    }

    if (uploadedDocuments.length === 0) {
      return jsonResponse({
        error: failures[0]?.error || "Nao foi possivel enviar os documentos.",
        stage: failures[0]?.stage || "batch_upload",
        erros: failures,
      }, 400);
    }

    if (uploadedDocuments.length === 1 && failures.length === 0) {
      return jsonResponse(uploadedDocuments[0]);
    }

    const uploadedBytes = uploadedDocuments.reduce((sum, document) => sum + document.tamanho_bytes, 0);

    return jsonResponse({
      documentos: uploadedDocuments,
      erros: failures,
      total_tamanho_bytes: uploadedBytes,
      tamanho_bytes: uploadedBytes,
      status_processamento: "processando",
    });
  } catch (error) {
    console.error("admin-upload-base-conhecimento unexpected error", error);
    return errorResponse("unexpected", error, 500);
  }
});
