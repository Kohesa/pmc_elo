import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  CheckCircle2,
  Database,
  FileText,
  FolderPlus,
  Loader2,
  RefreshCw,
  Search,
  ShieldCheck,
  Trash2,
  Upload,
} from "lucide-react";
import { isSupabaseConfigured, supabase } from "../lib/supabase";

const BUCKET_NAME = "base-conhecimento-documentos";

type Scope = "default_elo" | "publico";
type ProcessingStatus = "processando" | "processado" | "erro";
type IndexingStatus = "pendente" | "indexando" | "indexado" | "erro";

type CategoryRow = {
  id: string;
  nome: string | null;
  created_at: string | null;
  updated_at: string | null;
};

type DocumentRow = {
  id: string;
  tipo_relatorio: string | null;
  hora_criacao: string | null;
  documento: string | null;
  tema: string | null;
  categoria_id: string | null;
  url_documento: string | null;
  status_processamento: ProcessingStatus | null;
  status_indexacao: IndexingStatus | null;
  indexado_em: string | null;
  qtd_chunks: number | null;
  embedding_model: string | null;
  erro_indexacao: string | null;
  qtd_chunks_indexados?: number | null;
  qtd_chunks_total_indexacao?: number | null;
  percentual_indexacao?: number | null;
  tags?: string[] | null;
};

const scopes: Array<{ id: Scope; label: string; description: string }> = [
  {
    id: "default_elo",
    label: "Base padrão da Elo",
    description: "Conteúdo institucional e operacional usado pela IA da Elo.",
  },
  {
    id: "publico",
    label: "Catálogo público",
    description: "Conteúdo publicável usado nas pesquisas de serviços.",
  },
];

const statusLabel = (processing?: ProcessingStatus | null, indexing?: IndexingStatus | null) => {
  if (processing === "erro" || indexing === "erro") return "Erro";
  if (processing === "processando") return "Processando";
  if (indexing === "pendente") return "Pendente";
  if (indexing === "indexando") return "Indexando";
  if (indexing === "indexado") return "Indexado";
  return "Processado";
};

const statusClass = (processing?: ProcessingStatus | null, indexing?: IndexingStatus | null) => {
  if (processing === "erro" || indexing === "erro") return "border-red-100 bg-red-50 text-red-700";
  if (processing === "processando" || indexing === "indexando") return "border-blue-100 bg-blue-50 text-blue-700";
  if (indexing === "pendente") return "border-amber-100 bg-amber-50 text-amber-700";
  if (indexing === "indexado") return "border-emerald-100 bg-emerald-50 text-emerald-700";
  return "border-slate-200 bg-slate-100 text-slate-600";
};

const formatDateTime = (value?: string | null) => {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(date);
};

const getErrorMessage = (error: unknown, fallback: string) => {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "object" && error && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message.trim()) return message;
  }
  return fallback;
};

const getStoragePathFromUrl = (url: string | null) => {
  if (!url) return null;
  const marker = `/storage/v1/object/${BUCKET_NAME}/`;
  const markerIndex = url.indexOf(marker);
  if (markerIndex < 0) return null;

  const rawPath = url.slice(markerIndex + marker.length).split("?")[0];
  return rawPath
    .split("/")
    .map((part) => decodeURIComponent(part))
    .join("/");
};

const getFileName = (url: string | null) => {
  const storagePath = getStoragePathFromUrl(url);
  const rawName = storagePath?.split("/").pop() || "Documento";
  return rawName.replace(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-/i, "");
};

const hasWorkInProgress = (doc: DocumentRow) => (
  doc.status_processamento === "processando"
  || doc.status_indexacao === "pendente"
  || doc.status_indexacao === "indexando"
);

export default function AdminKnowledgeBase() {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [scope, setScope] = useState<Scope>("default_elo");
  const [categories, setCategories] = useState<CategoryRow[]>([]);
  const [documents, setDocuments] = useState<DocumentRow[]>([]);
  const [selectedCategoryId, setSelectedCategoryId] = useState("");
  const [newCategoryName, setNewCategoryName] = useState("");
  const [selectedFiles, setSelectedFiles] = useState<File[]>([]);
  const [textDocument, setTextDocument] = useState("");
  const [search, setSearch] = useState("");
  const [isCheckingAdmin, setIsCheckingAdmin] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isUploading, setIsUploading] = useState(false);
  const [isSavingText, setIsSavingText] = useState(false);
  const [categoryBusy, setCategoryBusy] = useState(false);
  const [busyDocumentId, setBusyDocumentId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const activeScope = scopes.find((item) => item.id === scope) || scopes[0];
  const canSubmit = selectedCategoryId && selectedFiles.length > 0 && !isUploading;
  const canSaveText = selectedCategoryId && textDocument.trim().length > 0 && !isSavingText;

  const loadData = useCallback(async (currentScope: Scope, options?: { silent?: boolean }) => {
    if (!isSupabaseConfigured || !supabase) {
      setError("Supabase nao esta configurado.");
      setIsLoading(false);
      return;
    }

    if (!options?.silent) {
      setIsLoading(true);
      setError(null);
    }

    try {
      const [categoriesResult, documentsResult] = await Promise.all([
        supabase.rpc("rpc_admin_kb_listar_categorias", { p_escopo: currentScope }),
        supabase.rpc("rpc_admin_kb_listar_documentos", { p_escopo: currentScope }),
      ]);

      if (categoriesResult.error) throw categoriesResult.error;
      if (documentsResult.error) throw documentsResult.error;

      const nextCategories = Array.isArray(categoriesResult.data)
        ? categoriesResult.data as CategoryRow[]
        : [];
      const nextDocuments = Array.isArray(documentsResult.data)
        ? documentsResult.data as DocumentRow[]
        : [];

      setCategories(nextCategories);
      setDocuments(nextDocuments);

      setSelectedCategoryId((current) => {
        if (current && nextCategories.some((category) => category.id === current)) return current;
        return nextCategories[0]?.id || "";
      });
    } catch (loadError) {
      setError(getErrorMessage(loadError, "Nao foi possivel carregar a base administrativa."));
      setCategories([]);
      setDocuments([]);
    } finally {
      if (!options?.silent) setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    let mounted = true;

    const checkAdmin = async () => {
      if (!isSupabaseConfigured || !supabase) {
        if (mounted) {
          setIsAdmin(false);
          setIsCheckingAdmin(false);
          setIsLoading(false);
        }
        return;
      }

      try {
        const { data, error: adminError } = await supabase.rpc("rpc_admin_kb_is_admin");
        if (adminError) throw adminError;

        if (!mounted) return;
        const allowed = data === true;
        setIsAdmin(allowed);
        setIsCheckingAdmin(false);

        if (allowed) {
          await loadData(scope);
        } else {
          setIsLoading(false);
        }
      } catch {
        if (!mounted) return;
        setIsAdmin(false);
        setIsCheckingAdmin(false);
        setIsLoading(false);
      }
    };

    void checkAdmin();

    return () => {
      mounted = false;
    };
  }, [loadData, scope]);

  useEffect(() => {
    if (!isAdmin) return;
    void loadData(scope);
  }, [isAdmin, loadData, scope]);

  useEffect(() => {
    if (!documents.some(hasWorkInProgress)) return;
    const intervalId = window.setInterval(() => {
      void loadData(scope, { silent: true });
    }, 6000);

    return () => window.clearInterval(intervalId);
  }, [documents, loadData, scope]);

  const filteredDocuments = useMemo(() => {
    const normalized = search.trim().toLowerCase();
    if (!normalized) return documents;

    return documents.filter((doc) => {
      const haystack = [
        doc.tema,
        doc.documento,
        getFileName(doc.url_documento),
        doc.status_processamento,
        doc.status_indexacao,
        doc.erro_indexacao,
      ].filter(Boolean).join(" ").toLowerCase();

      return haystack.includes(normalized);
    });
  }, [documents, search]);

  const createCategory = async () => {
    if (!newCategoryName.trim() || !supabase) return;

    setCategoryBusy(true);
    setError(null);
    setNotice(null);

    try {
      const { data, error: createError } = await supabase.rpc("rpc_admin_kb_criar_categoria", {
        p_nome: newCategoryName.trim(),
      });
      if (createError) throw createError;

      const created = Array.isArray(data) ? data[0] as CategoryRow | undefined : undefined;
      setNewCategoryName("");
      await loadData(scope, { silent: true });
      if (created?.id) setSelectedCategoryId(created.id);
      setNotice("Categoria criada.");
    } catch (createError) {
      setError(getErrorMessage(createError, "Nao foi possivel criar a categoria."));
    } finally {
      setCategoryBusy(false);
    }
  };

  const uploadFiles = async () => {
    if (!canSubmit || !supabase) return;

    setIsUploading(true);
    setError(null);
    setNotice(null);

    try {
      const formData = new FormData();
      formData.append("escopo", scope);
      formData.append("categoria_id", selectedCategoryId);
      selectedFiles.forEach((file) => formData.append("files", file));

      const { error: uploadError } = await supabase.functions.invoke("admin-upload-base-conhecimento", {
        body: formData,
      });
      if (uploadError) throw uploadError;

      setSelectedFiles([]);
      if (fileInputRef.current) fileInputRef.current.value = "";
      await loadData(scope, { silent: true });
      setNotice("Upload enviado para processamento.");
    } catch (uploadError) {
      setError(getErrorMessage(uploadError, "Nao foi possivel enviar os documentos."));
    } finally {
      setIsUploading(false);
    }
  };

  const saveTextDocument = async () => {
    if (!canSaveText || !supabase) return;

    setIsSavingText(true);
    setError(null);
    setNotice(null);

    try {
      const { error: saveError } = await supabase.rpc("rpc_admin_kb_inserir_documento_texto", {
        p_escopo: scope,
        p_categoria_id: selectedCategoryId,
        p_documento: textDocument.trim(),
      });
      if (saveError) throw saveError;

      setTextDocument("");
      await loadData(scope, { silent: true });
      setNotice("Documento de texto salvo.");
    } catch (saveError) {
      setError(getErrorMessage(saveError, "Nao foi possivel salvar o documento de texto."));
    } finally {
      setIsSavingText(false);
    }
  };

  const deleteDocument = async (doc: DocumentRow) => {
    if (!supabase || busyDocumentId) return;
    const confirmed = window.confirm("Excluir este documento da base administrativa?");
    if (!confirmed) return;

    setBusyDocumentId(doc.id);
    setError(null);
    setNotice(null);

    try {
      const storagePath = getStoragePathFromUrl(doc.url_documento);
      const { error: deleteError } = await supabase.rpc("rpc_admin_kb_excluir_documento", {
        p_id: doc.id,
      });
      if (deleteError) throw deleteError;

      if (storagePath) {
        const { error: storageError } = await supabase.storage.from(BUCKET_NAME).remove([storagePath]);
        if (storageError) {
          setError(getErrorMessage(storageError, "Documento excluido, mas nao foi possivel remover o arquivo do storage."));
        }
      }

      await loadData(scope, { silent: true });
      setNotice("Documento excluido.");
    } catch (deleteError) {
      setError(getErrorMessage(deleteError, "Nao foi possivel excluir o documento."));
    } finally {
      setBusyDocumentId(null);
    }
  };

  const reprocessDocument = async (doc: DocumentRow) => {
    if (!supabase || busyDocumentId) return;

    setBusyDocumentId(doc.id);
    setError(null);
    setNotice(null);

    try {
      const { error: reprocessError } = await supabase.rpc("rpc_admin_kb_reprocessar_documento", {
        p_id: doc.id,
      });
      if (reprocessError) throw reprocessError;

      await loadData(scope, { silent: true });
      setNotice("Reprocessamento solicitado.");
    } catch (reprocessError) {
      setError(getErrorMessage(reprocessError, "Nao foi possivel solicitar o reprocessamento."));
    } finally {
      setBusyDocumentId(null);
    }
  };

  if (isCheckingAdmin || isLoading) {
    return (
      <div className="min-h-screen bg-[#F8FAFC] flex items-center justify-center text-[#091E42]">
        <Loader2 className="mr-3 animate-spin text-[#14FECC]" size={22} />
        <span className="text-sm font-black uppercase tracking-[0.2em]">Carregando admin docs</span>
      </div>
    );
  }

  if (!isAdmin) {
    return (
      <div className="min-h-screen bg-[#F8FAFC] px-6 py-10">
        <div className="max-w-3xl mx-auto border border-red-100 bg-white p-8 shadow-sm">
          <div className="flex items-center gap-3 text-red-700">
            <ShieldCheck size={22} />
            <h1 className="text-lg font-black">Acesso administrativo necessario</h1>
          </div>
          <p className="mt-3 text-sm font-medium text-[#44546F]">
            Seu usuario nao possui o perfil admin_docs.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#F8FAFC] px-4 py-6 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <header className="flex flex-col gap-4 border-b border-slate-200 pb-6 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <div className="flex items-center gap-3 text-[#02403D]">
              <Database size={24} className="text-[#14FECC]" />
              <span className="text-[10px] font-black uppercase tracking-[0.24em]">Admin Docs</span>
            </div>
            <h1 className="mt-2 text-2xl font-black text-[#091E42] sm:text-3xl">
              Base de conhecimento do produto
            </h1>
            <p className="mt-2 max-w-2xl text-sm font-medium text-[#44546F]">
              {activeScope.description}
            </p>
          </div>

          <button
            type="button"
            onClick={() => loadData(scope)}
            className="inline-flex h-11 items-center justify-center gap-2 border border-slate-200 bg-white px-4 text-sm font-black text-[#02403D] shadow-sm transition hover:border-[#14FECC]"
          >
            <RefreshCw size={16} />
            Atualizar
          </button>
        </header>

        <section className="grid gap-3 sm:grid-cols-2">
          {scopes.map((item) => {
            const active = item.id === scope;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => setScope(item.id)}
                className={`border p-4 text-left transition ${
                  active
                    ? "border-[#14FECC] bg-white shadow-sm"
                    : "border-slate-200 bg-white/70 hover:border-slate-300"
                }`}
              >
                <div className="flex items-center justify-between gap-3">
                  <span className="text-sm font-black text-[#091E42]">{item.label}</span>
                  {active && <CheckCircle2 size={18} className="text-[#14FECC]" />}
                </div>
                <p className="mt-2 text-xs font-medium text-[#5E6C84]">{item.description}</p>
              </button>
            );
          })}
        </section>

        {(error || notice) && (
          <section className={`flex items-start gap-3 border p-4 ${
            error ? "border-red-100 bg-red-50 text-red-700" : "border-emerald-100 bg-emerald-50 text-emerald-700"
          }`}>
            {error ? <AlertCircle size={18} /> : <CheckCircle2 size={18} />}
            <p className="text-sm font-bold">{error || notice}</p>
          </section>
        )}

        <section className="grid gap-4 lg:grid-cols-[minmax(320px,420px)_1fr]">
          <div className="space-y-4">
            <div className="border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex items-center gap-2 text-[#091E42]">
                <FolderPlus size={18} className="text-[#14FECC]" />
                <h2 className="text-sm font-black uppercase tracking-[0.18em]">Categorias</h2>
              </div>

              <div className="mt-4 space-y-3">
                <select
                  value={selectedCategoryId}
                  onChange={(event) => setSelectedCategoryId(event.target.value)}
                  className="h-11 w-full border border-slate-200 bg-white px-3 text-sm font-bold text-[#091E42] outline-none transition focus:border-[#14FECC]"
                >
                  {categories.length === 0 ? (
                    <option value="">Crie uma categoria</option>
                  ) : (
                    categories.map((category) => (
                      <option key={category.id} value={category.id}>
                        {category.nome || "Sem nome"}
                      </option>
                    ))
                  )}
                </select>

                <div className="flex gap-2">
                  <input
                    value={newCategoryName}
                    onChange={(event) => setNewCategoryName(event.target.value)}
                    placeholder="Nova categoria"
                    className="h-11 min-w-0 flex-1 border border-slate-200 px-3 text-sm font-bold text-[#091E42] outline-none transition placeholder:text-slate-400 focus:border-[#14FECC]"
                  />
                  <button
                    type="button"
                    onClick={createCategory}
                    disabled={!newCategoryName.trim() || categoryBusy}
                    className="inline-flex h-11 items-center justify-center gap-2 bg-[#02403D] px-4 text-sm font-black text-white transition hover:bg-[#03524E] disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {categoryBusy ? <Loader2 size={16} className="animate-spin" /> : <FolderPlus size={16} />}
                    Criar
                  </button>
                </div>
              </div>
            </div>

            <div className="border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex items-center gap-2 text-[#091E42]">
                <Upload size={18} className="text-[#14FECC]" />
                <h2 className="text-sm font-black uppercase tracking-[0.18em]">Upload PDF</h2>
              </div>

              <div className="mt-4 space-y-3">
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="application/pdf,.pdf"
                  multiple
                  onChange={(event) => setSelectedFiles(Array.from(event.target.files || []))}
                  className="block w-full text-sm font-bold text-[#44546F] file:mr-4 file:h-10 file:border-0 file:bg-[#E6FCF6] file:px-4 file:text-xs file:font-black file:uppercase file:tracking-widest file:text-[#02403D]"
                />

                {selectedFiles.length > 0 && (
                  <div className="space-y-1 border border-slate-100 bg-slate-50 p-3">
                    {selectedFiles.map((file) => (
                      <p key={`${file.name}-${file.size}`} className="truncate text-xs font-bold text-[#44546F]">
                        {file.name}
                      </p>
                    ))}
                  </div>
                )}

                <button
                  type="button"
                  onClick={uploadFiles}
                  disabled={!canSubmit}
                  className="inline-flex h-11 w-full items-center justify-center gap-2 bg-[#14FECC] px-4 text-sm font-black text-[#02403D] transition hover:bg-[#47FFD9] disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {isUploading ? <Loader2 size={16} className="animate-spin" /> : <Upload size={16} />}
                  Enviar para processamento
                </button>
              </div>
            </div>

            <div className="border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex items-center gap-2 text-[#091E42]">
                <FileText size={18} className="text-[#14FECC]" />
                <h2 className="text-sm font-black uppercase tracking-[0.18em]">Texto direto</h2>
              </div>

              <textarea
                value={textDocument}
                onChange={(event) => setTextDocument(event.target.value)}
                rows={7}
                placeholder="Cole o conteudo do documento"
                className="mt-4 w-full resize-y border border-slate-200 p-3 text-sm font-medium text-[#091E42] outline-none transition placeholder:text-slate-400 focus:border-[#14FECC]"
              />

              <button
                type="button"
                onClick={saveTextDocument}
                disabled={!canSaveText}
                className="mt-3 inline-flex h-11 w-full items-center justify-center gap-2 bg-[#02403D] px-4 text-sm font-black text-white transition hover:bg-[#03524E] disabled:cursor-not-allowed disabled:opacity-50"
              >
                {isSavingText ? <Loader2 size={16} className="animate-spin" /> : <FileText size={16} />}
                Salvar texto
              </button>
            </div>
          </div>

          <div className="border border-slate-200 bg-white shadow-sm">
            <div className="flex flex-col gap-4 border-b border-slate-100 p-5 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <h2 className="text-sm font-black uppercase tracking-[0.18em] text-[#091E42]">
                  Documentos
                </h2>
                <p className="mt-1 text-xs font-bold text-[#5E6C84]">
                  {filteredDocuments.length} resultado{filteredDocuments.length === 1 ? "" : "s"}
                </p>
              </div>

              <label className="relative block w-full lg:w-80">
                <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
                <input
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Buscar"
                  className="h-11 w-full border border-slate-200 pl-10 pr-3 text-sm font-bold text-[#091E42] outline-none transition placeholder:text-slate-400 focus:border-[#14FECC]"
                />
              </label>
            </div>

            <div className="divide-y divide-slate-100">
              {filteredDocuments.length === 0 ? (
                <div className="p-10 text-center">
                  <Database size={30} className="mx-auto text-slate-300" />
                  <p className="mt-3 text-sm font-black text-[#091E42]">Nenhum documento neste escopo.</p>
                </div>
              ) : (
                filteredDocuments.map((doc) => {
                  const progress = typeof doc.percentual_indexacao === "number" ? doc.percentual_indexacao : null;
                  const busy = busyDocumentId === doc.id;

                  return (
                    <article key={doc.id} className="p-5">
                      <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            <span className={`inline-flex items-center border px-2.5 py-1 text-[10px] font-black uppercase tracking-widest ${statusClass(doc.status_processamento, doc.status_indexacao)}`}>
                              {statusLabel(doc.status_processamento, doc.status_indexacao)}
                            </span>
                            <span className="text-xs font-black text-[#02403D]">{doc.tema || "Sem categoria"}</span>
                            <span className="text-xs font-bold text-[#7A869A]">{formatDateTime(doc.hora_criacao)}</span>
                          </div>

                          <h3 className="mt-3 truncate text-base font-black text-[#091E42]">
                            {getFileName(doc.url_documento)}
                          </h3>

                          {doc.documento ? (
                            <p className="mt-2 line-clamp-2 text-sm font-medium text-[#44546F]">
                              {doc.documento}
                            </p>
                          ) : (
                            <p className="mt-2 text-sm font-medium text-[#7A869A]">
                              Aguardando extracao do conteudo.
                            </p>
                          )}

                          {doc.erro_indexacao && (
                            <p className="mt-2 text-xs font-bold text-red-600">{doc.erro_indexacao}</p>
                          )}

                          {doc.status_indexacao === "indexando" && (
                            <div className="mt-4">
                              <div className="mb-1 flex items-center justify-between text-[10px] font-black uppercase tracking-widest text-blue-700">
                                <span>Indexacao</span>
                                <span>{progress === null ? "Calculando" : `${progress}%`}</span>
                              </div>
                              <div className="h-2 overflow-hidden bg-blue-50">
                                <div
                                  className="h-full bg-[#14FECC] transition-all"
                                  style={{ width: `${progress ?? 8}%` }}
                                />
                              </div>
                            </div>
                          )}
                        </div>

                        <div className="flex shrink-0 flex-wrap gap-2">
                          <button
                            type="button"
                            onClick={() => reprocessDocument(doc)}
                            disabled={busyDocumentId !== null || !doc.url_documento}
                            className="inline-flex h-10 items-center justify-center gap-2 border border-slate-200 bg-white px-3 text-xs font-black text-[#02403D] transition hover:border-[#14FECC] disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            {busy ? <Loader2 size={15} className="animate-spin" /> : <RefreshCw size={15} />}
                            Reprocessar
                          </button>
                          <button
                            type="button"
                            onClick={() => deleteDocument(doc)}
                            disabled={busyDocumentId !== null}
                            className="inline-flex h-10 items-center justify-center gap-2 border border-red-100 bg-red-50 px-3 text-xs font-black text-red-700 transition hover:bg-red-100 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            {busy ? <Loader2 size={15} className="animate-spin" /> : <Trash2 size={15} />}
                            Excluir
                          </button>
                        </div>
                      </div>
                    </article>
                  );
                })
              )}
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}
