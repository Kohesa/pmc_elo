import { useEffect, useState, type FormEvent } from "react";
import { Loader2, LockKeyhole } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { isSupabaseConfigured, supabase } from "../lib/supabase";

export default function Login() {
  const navigate = useNavigate(); const [email, setEmail] = useState(""); const [password, setPassword] = useState(""); const [loading, setLoading] = useState(false); const [error, setError] = useState("");
  useEffect(() => { if (!supabase) return; void supabase.auth.getSession().then(({ data }) => { if (data.session) navigate("/admin/knowledge", { replace: true }); }); }, [navigate]);
  const submit = async (event: FormEvent) => {
    event.preventDefault(); if (!isSupabaseConfigured || !supabase) { setError("Supabase não está configurado."); return; }
    setLoading(true); setError(""); const { error: loginError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (loginError) { setError("E-mail ou senha inválidos."); setLoading(false); return; }
    const { data: allowed, error: permissionError } = await supabase.rpc("rpc_admin_kb_is_admin");
    if (permissionError || allowed !== true) { await supabase.auth.signOut({ scope: "local" }); setError("Este usuário não possui acesso administrativo."); setLoading(false); return; }
    navigate("/admin/knowledge", { replace: true });
  };
  return <main className="grid min-h-screen place-items-center bg-slate-100 px-6"><form onSubmit={submit} className="w-full max-w-md rounded-3xl border border-slate-200 bg-white p-8 shadow-xl"><div className="mb-7 grid h-12 w-12 place-items-center rounded-xl bg-emerald-900 text-white"><LockKeyhole size={22} /></div><p className="text-xs font-black uppercase tracking-[0.25em] text-emerald-700">Elo Connect</p><h1 className="mt-2 text-2xl font-black text-slate-900">Acesso administrativo</h1><p className="mt-2 text-sm text-slate-500">Entre para gerenciar documentos da IA e consultar cadastros.</p><div className="mt-7 space-y-4"><label className="block text-sm font-bold text-slate-700">E-mail<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 font-normal outline-none focus:border-emerald-700" /></label><label className="block text-sm font-bold text-slate-700">Senha<input type="password" required value={password} onChange={(event) => setPassword(event.target.value)} className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 font-normal outline-none focus:border-emerald-700" /></label></div>{error && <p className="mt-4 rounded-xl bg-red-50 p-3 text-sm font-semibold text-red-700">{error}</p>}<button disabled={loading} className="mt-6 flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-900 px-4 py-3 font-black text-white disabled:opacity-60">{loading && <Loader2 className="animate-spin" size={18} />} Entrar</button></form></main>;
}
