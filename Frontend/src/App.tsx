import { useEffect, useState, type ReactNode } from "react";
import { BrowserRouter, Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import AdminLayout from "./components/AdminLayout";
import AdminCadastros from "./pages/AdminCadastros";
import AdminKnowledgeBase from "./pages/AdminKnowledgeBase";
import Landing from "./pages/Landing";
import LegalPage from "./pages/LegalPage";
import Login from "./pages/Login";
import { isSupabaseConfigured, supabase } from "./lib/supabase";

function ProtectedAdmin({ children }: { children: ReactNode }) {
  const location = useLocation();
  const [state, setState] = useState<"loading" | "allowed" | "denied">("loading");

  useEffect(() => {
    let active = true;
    if (!isSupabaseConfigured || !supabase) {
      setState("denied");
      return;
    }
    void (async () => {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) return false;
      const { data, error } = await supabase.rpc("rpc_admin_kb_is_admin");
      if (error) throw error;
      return data === true;
    })().then((allowed) => {
      if (active) setState(allowed ? "allowed" : "denied");
    }).catch(() => {
      if (active) setState("denied");
    });
    return () => { active = false; };
  }, []);

  if (state === "loading") return <div className="grid min-h-screen place-items-center text-sm font-semibold text-slate-600">Carregando...</div>;
  if (state === "denied") return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  return <>{children}</>;
}

function AdminShell() {
  return <AdminLayout><Outlet /></AdminLayout>;
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Landing />} />
        <Route path="/login" element={<Login />} />
        <Route path="/terms" element={<LegalPage kind="terms" />} />
        <Route path="/privacy" element={<LegalPage kind="privacy" />} />
        <Route element={<ProtectedAdmin><AdminShell /></ProtectedAdmin>}>
          <Route path="/admin/knowledge" element={<AdminKnowledgeBase />} />
          <Route path="/admin/cadastros" element={<AdminCadastros />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
