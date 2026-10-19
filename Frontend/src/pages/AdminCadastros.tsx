import { useCallback, useEffect, useState } from "react";
import { Loader2, Search, Users } from "lucide-react";
import { isSupabaseConfigured, supabase } from "../lib/supabase";

type CadastroRow = {
  id: string;
  nome: string | null;
  tipo: string | null;
  telefone: string | null;
  email: string | null;
  empresa: string | null;
  cargo: string | null;
  status: string | null;
  perfil_ativo: boolean;
  autoriza_publicacao: boolean;
  cadastro_concluido_em: string | null;
  total_servicos: number;
  servicos_publicados: number;
  documentos_indexados: number;
  created_at: string;
  updated_at: string;
};
const formatDate = (value: string) => new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" }).format(new Date(value));

export default function AdminCadastros() {
  const [rows, setRows] = useState<CadastroRow[]>([]);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    if (!isSupabaseConfigured || !supabase) { setError("Supabase não está configurado."); setLoading(false); return; }
    setLoading(true); setError("");
    const { data, error: rpcError } = await supabase.rpc("rpc_admin_listar_cadastros", { p_busca: search.trim() || null, p_limit: 200, p_offset: 0 });
    if (rpcError) setError(rpcError.message || "Não foi possível carregar os cadastros.");
    else setRows(Array.isArray(data) ? data as CadastroRow[] : []);
    setLoading(false);
  }, [search]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 250); return () => window.clearTimeout(timer); }, [load]);

  return (
    <section className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div><p className="text-xs font-black uppercase tracking-[0.2em] text-emerald-700">Operação interna</p><h2 className="mt-1 text-3xl font-black text-slate-900">Cadastros da Elo</h2><p className="mt-2 text-sm text-slate-600">Consulta de participantes, serviços publicados e situação da indexação.</p></div>
        <label className="relative block w-full max-w-sm"><Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={18} /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Buscar por nome, empresa, e-mail ou telefone" className="w-full rounded-xl border border-slate-200 bg-white py-3 pl-10 pr-4 text-sm outline-none focus:border-emerald-700" /></label>
      </div>
      {error && <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-700">{error}</div>}
      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
        {loading ? <div className="flex items-center justify-center gap-2 p-12 text-sm font-semibold text-slate-500"><Loader2 className="animate-spin" size={18} /> Carregando cadastros...</div> : rows.length === 0 ? <div className="grid place-items-center gap-2 p-12 text-center text-slate-500"><Users size={30} /><p className="text-sm font-semibold">Nenhum cadastro encontrado.</p></div> : (
          <div className="overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-4 py-3">Pessoa</th><th className="px-4 py-3">Contato</th><th className="px-4 py-3">Empresa</th><th className="px-4 py-3">Publicação</th><th className="px-4 py-3">Serviços</th><th className="px-4 py-3">Atualizado</th></tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => {
            const publicado = row.status === "aprovado" && row.perfil_ativo && row.autoriza_publicacao && Boolean(row.cadastro_concluido_em);
            return <tr key={row.id} className="hover:bg-slate-50"><td className="px-4 py-3"><p className="font-bold text-slate-900">{row.nome || "Sem nome"}</p><p className="text-xs text-slate-500">{row.tipo || "Cadastro"}</p></td><td className="px-4 py-3"><p>{row.telefone || "-"}</p><p className="text-xs text-slate-500">{row.email || "-"}</p></td><td className="px-4 py-3"><p className="font-semibold">{row.empresa || "-"}</p><p className="text-xs text-slate-500">{row.cargo || "-"}</p></td><td className="px-4 py-3"><span className={`rounded-full px-2.5 py-1 text-xs font-black ${publicado ? "bg-emerald-50 text-emerald-800" : "bg-slate-100 text-slate-600"}`}>{publicado ? "Autorizado" : row.status || "Incompleto"}</span></td><td className="px-4 py-3"><p className="font-semibold text-slate-800">{Number(row.servicos_publicados || 0)} de {Number(row.total_servicos || 0)} publicados</p><p className="text-xs text-slate-500">{Number(row.documentos_indexados || 0)} indexados</p></td><td className="px-4 py-3 text-xs text-slate-500">{formatDate(row.updated_at || row.created_at)}</td></tr>;
          })}</tbody></table></div>
        )}
      </div>
    </section>
  );
}
