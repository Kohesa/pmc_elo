import type { ReactNode } from "react";
import { Database, LogOut, Users } from "lucide-react";
import { NavLink, useNavigate } from "react-router-dom";
import { supabase } from "../lib/supabase";

export default function AdminLayout({ children }: { children: ReactNode }) {
  const navigate = useNavigate();
  const logout = async () => {
    await supabase?.auth.signOut({ scope: "local" });
    navigate("/login", { replace: true });
  };
  const itemClass = ({ isActive }: { isActive: boolean }) => `flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-bold transition ${isActive ? "bg-emerald-900 text-white" : "text-slate-600 hover:bg-slate-100"}`;

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-6 px-5 py-4">
          <div><p className="text-xs font-black uppercase tracking-[0.25em] text-emerald-700">Elo Connect</p><h1 className="text-lg font-black text-slate-900">Administração</h1></div>
          <nav className="flex flex-1 items-center gap-2">
            <NavLink to="/admin/knowledge" className={itemClass}><Database size={17} /> Documentos da IA</NavLink>
            <NavLink to="/admin/cadastros" className={itemClass}><Users size={17} /> Cadastros</NavLink>
          </nav>
          <button onClick={logout} className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-bold text-slate-600 hover:bg-slate-100"><LogOut size={17} /> Sair</button>
        </div>
      </header>
      <main className="mx-auto max-w-7xl px-5 py-8">{children}</main>
    </div>
  );
}
