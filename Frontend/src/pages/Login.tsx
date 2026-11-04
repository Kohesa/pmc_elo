import { useEffect, useState, type FormEvent } from "react";
import { Loader2, LockKeyhole } from "lucide-react";
import { useNavigate } from "react-router-dom";
import ParticipantShell from "../components/ParticipantShell";
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
  return (
    <ParticipantShell
      eyebrow="Operação interna"
      title="Acesso administrativo"
      subtitle="Entre para gerenciar os documentos da IA e consultar os cadastros da Elo."
    >
      <form onSubmit={submit} className="admin-login-form">
        <div className="admin-login-form__icon" aria-hidden="true"><LockKeyhole size={23} /></div>
        <div className="admin-login-form__fields">
          <label>E-mail<input type="email" autoComplete="email" required value={email} onChange={(event) => setEmail(event.target.value)} /></label>
          <label>Senha<input type="password" autoComplete="current-password" required value={password} onChange={(event) => setPassword(event.target.value)} /></label>
        </div>
        {error && <p className="admin-login-form__error" role="alert">{error}</p>}
        <button disabled={loading} className="admin-login-form__submit">{loading && <Loader2 className="animate-spin" size={18} />} Entrar</button>
      </form>
    </ParticipantShell>
  );
}
