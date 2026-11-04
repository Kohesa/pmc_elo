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
  const itemClass = ({ isActive }: { isActive: boolean }) => `admin-portal__nav-item${isActive ? " admin-portal__nav-item--active" : ""}`;

  return (
    <div className="admin-portal">
      <header className="admin-portal__header">
        <div className="admin-portal__header-inner">
          <NavLink className="connect-brand admin-portal__brand" to="/" aria-label="Connect — Ministério de Empreendedores">
            <span className="connect-brand__wordmark">CONNECT</span>
            <img className="connect-brand__symbol" src="/elo-landing/4a63e.png" alt="" />
            <span className="connect-brand__subtitle">MINISTÉRIO DE EMPREENDEDORES</span>
          </NavLink>
          <div className="admin-portal__context"><span>Operação interna</span><strong>Administração</strong></div>
          <nav className="admin-portal__nav" aria-label="Administração da Elo">
            <NavLink to="/admin/knowledge" className={itemClass}><Database size={17} /> Documentos da IA</NavLink>
            <NavLink to="/admin/cadastros" className={itemClass}><Users size={17} /> Cadastros</NavLink>
          </nav>
          <button onClick={logout} className="admin-portal__logout"><LogOut size={17} /> Sair</button>
        </div>
      </header>
      <main className="admin-portal__main">{children}</main>
    </div>
  );
}
