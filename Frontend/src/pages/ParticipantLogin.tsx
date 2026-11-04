import { useState, type FormEvent } from "react";
import { Loader2 } from "lucide-react";
import { Link, useNavigate } from "react-router-dom";
import ParticipantShell from "../components/ParticipantShell";
import { isSupabaseConfigured, supabase } from "../lib/supabase";
import { messageFromError } from "../lib/participant";

export default function ParticipantLogin() {
  const navigate = useNavigate();
  const [mode, setMode] = useState<"password" | "code">("password");
  const [otp, setOtp] = useState("");
  const [otpSent, setOtpSent] = useState(false);
  const [otpVerified, setOtpVerified] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const sendOtp = async (event: FormEvent) => {
    event.preventDefault();
    if (!isSupabaseConfigured || !supabase) return setError("Supabase não está configurado.");
    const normalizedEmail = email.trim().toLowerCase();
    if (!normalizedEmail) return setError("Informe seu e-mail.");
    setLoading(true); setError("");
    const { error: requestError } = await supabase.auth.signInWithOtp({ email: normalizedEmail, options: { shouldCreateUser: false } });
    setLoading(false);
    if (requestError) return setError(messageFromError(requestError, "Não foi possível enviar o código."));
    setEmail(normalizedEmail); setOtpSent(true);
  };

  const verifyOtp = async (event: FormEvent) => {
    event.preventDefault();
    if (!supabase) return;
    setLoading(true); setError("");
    const { error: verifyError } = await supabase.auth.verifyOtp({ email, token: otp.trim(), type: "email" });
    setLoading(false);
    if (verifyError) return setError(messageFromError(verifyError, "Código inválido ou expirado."));
    setOtpVerified(true);
  };

  const definePassword = async (event: FormEvent) => {
    event.preventDefault();
    if (!supabase) return;
    setLoading(true); setError("");
    const { error: updateError } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (updateError) return setError(messageFromError(updateError, "Não foi possível definir a senha."));
    navigate("/meu-cadastro", { replace: true });
  };

  const signInEmail = async (event: FormEvent) => {
    event.preventDefault();
    if (!supabase) return setError("Supabase não está configurado.");
    setLoading(true); setError("");
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setLoading(false);
    if (signInError) return setError("E-mail ou senha inválidos.");
    navigate("/meu-cadastro", { replace: true });
  };

  return (
    <ParticipantShell title="Entrar no meu cadastro" subtitle="O e-mail de acesso identifica seu cadastro, independentemente do canal em que você conversou com a Elo.">
      <div className="mb-6 grid grid-cols-2 rounded-xl bg-slate-100 p-1">
        <button onClick={() => { setMode("password"); setError(""); }} className={`rounded-lg px-3 py-2 text-sm font-black ${mode === "password" ? "bg-white text-emerald-900 shadow" : "text-slate-500"}`}>E-mail e senha</button>
        <button onClick={() => { setMode("code"); setError(""); }} className={`rounded-lg px-3 py-2 text-sm font-black ${mode === "code" ? "bg-white text-emerald-900 shadow" : "text-slate-500"}`}>Primeiro acesso</button>
      </div>
      {mode === "password" && <form onSubmit={signInEmail} className="space-y-4"><Field label="E-mail" type="email" value={email} onChange={setEmail} /><Field label="Senha" type="password" value={password} onChange={setPassword} /><Submit loading={loading}>Entrar</Submit></form>}
      {mode === "code" && !otpSent && <form onSubmit={sendOtp} className="space-y-4"><p className="rounded-xl bg-emerald-50 p-4 text-sm leading-6 text-emerald-950">Use esta opção se criou o cadastro pelo chatbot ou ainda não definiu uma senha.</p><Field label="E-mail confirmado no cadastro" type="email" value={email} onChange={setEmail} /><Submit loading={loading}>Enviar código</Submit></form>}
      {mode === "code" && otpSent && !otpVerified && <form onSubmit={verifyOtp} className="space-y-4"><Field label="Código recebido por e-mail" value={otp} onChange={setOtp} inputMode="numeric" autoComplete="one-time-code" /><Submit loading={loading}>Confirmar código</Submit><button type="button" onClick={() => { setOtpSent(false); setOtp(""); }} className="w-full text-sm font-bold text-slate-500">Trocar e-mail</button></form>}
      {mode === "code" && otpVerified && <form onSubmit={definePassword} className="space-y-4"><Field label="Crie uma senha" type="password" value={password} onChange={setPassword} /><Submit loading={loading}>Definir senha e entrar</Submit></form>}
      {error && <p className="mt-4 rounded-xl bg-red-50 p-3 text-sm font-semibold text-red-700">{error}</p>}
      <p className="mt-7 text-center text-sm text-slate-600">Ainda não possui cadastro? <Link to="/cadastro" className="font-black text-emerald-800">Criar pela web</Link></p>
    </ParticipantShell>
  );
}

function Field({ label, value, onChange, type = "text", inputMode, autoComplete }: { label: string; value: string; onChange: (value: string) => void; type?: string; inputMode?: "tel" | "numeric"; autoComplete?: string }) {
  return <label className="block text-sm font-bold text-slate-700">{label}<input required type={type} inputMode={inputMode} autoComplete={autoComplete} value={value} onChange={(event) => onChange(event.target.value)} className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 font-normal outline-none focus:border-emerald-700" /></label>;
}

function Submit({ loading, children }: { loading: boolean; children: string }) {
  return <button disabled={loading} className="flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-900 px-4 py-3 font-black text-white disabled:opacity-60">{loading && <Loader2 className="animate-spin" size={18} />}{children}</button>;
}

