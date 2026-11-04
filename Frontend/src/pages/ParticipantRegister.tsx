import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Loader2 } from "lucide-react";
import { Link, useNavigate } from "react-router-dom";
import ParticipantShell from "../components/ParticipantShell";
import { isSupabaseConfigured, supabase } from "../lib/supabase";
import { messageFromError } from "../lib/participant";

type Step = "form" | "account";

const PASSWORD_MIN_LENGTH = 10;

const emptyForm = {
  nome: "", nome_preferido: "", empresa_nome: "", empresa_descricao: "", setor: "",
  site: "", instagram: "", linkedin: "", servico_nome: "", servico_descricao: "",
  telefone: "", empresa_telefone: "", empresa_email: "",
  autoriza_publicacao: true, publicar_telefone: false, publicar_email: false, aceita_termos: false,
};

export default function ParticipantRegister() {
  const navigate = useNavigate();
  const [step, setStep] = useState<Step>("form");
  const [email, setEmail] = useState(""); const [password, setPassword] = useState("");
  const [passwordConfirmation, setPasswordConfirmation] = useState("");
  const [form, setForm] = useState(emptyForm);
  const [authenticated, setAuthenticated] = useState(false);
  const [loading, setLoading] = useState(false); const [error, setError] = useState("");

  useEffect(() => {
    if (!supabase) return;
    void supabase.auth.getSession().then(async ({ data }) => {
      if (!data.session) return;
      if (!data.session.user.email_confirmed_at) return;
      setAuthenticated(true);
      setEmail(data.session.user.email || "");
      const { data: current } = await supabase.rpc("rpc_meu_cadastro");
      const profile = current as { cadastrado?: boolean; cadastro?: { nome?: string; nome_preferido?: string; telefone?: string }; empresa?: { nome?: string; descricao_negocio?: string; setor?: string; links_publicos?: Array<{ tipo?: string; url?: string }>; publicado?: boolean; telefone_contato?: string | null; email_contato?: string | null; telefone_publico?: string | null; email_publico?: string | null }; servicos?: Array<{ nome?: string; descricao?: string }> } | null;
      if (profile?.cadastrado) {
        const links = profile.empresa?.links_publicos || [];
        const link = (type: string) => links.find((item) => item.tipo === type)?.url || "";
        const service = profile.servicos?.[0];
        setForm({
          ...emptyForm,
          nome: profile.cadastro?.nome || "",
          nome_preferido: profile.cadastro?.nome_preferido || "",
          empresa_nome: profile.empresa?.nome || "",
          empresa_descricao: profile.empresa?.descricao_negocio || "",
          setor: profile.empresa?.setor || "",
          site: link("site"), instagram: link("instagram"), linkedin: link("linkedin"),
          servico_nome: service?.nome || "", servico_descricao: service?.descricao || "",
          telefone: profile.cadastro?.telefone || "",
          empresa_telefone: profile.empresa?.telefone_contato || profile.empresa?.telefone_publico || "",
          empresa_email: profile.empresa?.email_contato || profile.empresa?.email_publico || "",
          autoriza_publicacao: profile.empresa?.publicado ?? false,
          publicar_telefone: Boolean(profile.empresa?.telefone_publico),
          publicar_email: Boolean(profile.empresa?.email_publico),
          aceita_termos: true,
        });
      }
    });
  }, []);

  const persistRegistration = async () => {
    if (!supabase) return;
    setLoading(true); setError("");
    const { error: saveError } = await supabase.rpc("rpc_cadastro_web_salvar", { p_dados: form });
    setLoading(false);
    if (saveError) {
      setStep("form");
      return setError(messageFromError(saveError, "Não foi possível salvar o cadastro."));
    }
    navigate("/meu-cadastro", { replace: true });
  };

  const continueFromForm = async (event: FormEvent) => {
    event.preventDefault();
    if (!isSupabaseConfigured || !supabase) return setError("Supabase não está configurado.");
    setError("");
    if (authenticated) return persistRegistration();
    setStep("account");
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const createAccount = async (event: FormEvent) => {
    event.preventDefault(); if (!isSupabaseConfigured || !supabase) return setError("Supabase não está configurado.");
    const passwordError = validateStrongPassword(password);
    if (passwordError) return setError(passwordError);
    if (password !== passwordConfirmation) return setError("As senhas informadas não são iguais.");
    setLoading(true); setError("");
    const normalizedEmail = email.trim().toLowerCase();
    const { data, error: signupError } = await supabase.auth.signUp({ email: normalizedEmail, password });
    setLoading(false);
    if (signupError) return setError(messageFromError(signupError, "Não foi possível criar a conta."));
    if (!data.session) return setError("Não foi possível iniciar a sessão. Se este e-mail já possui conta, use a opção Entrar.");
    setAuthenticated(true);
    await persistRegistration();
  };

  return (
    <ParticipantShell title="Cadastro na Elo" subtitle="Os dados de autenticação ficam privados. A empresa e o serviço só entram na pesquisa com autorização expressa.">
      {!authenticated && <StepIndicator step={step} />}
      {step === "account" && <form onSubmit={createAccount} className="space-y-4">
        <Notice>Seus dados foram mantidos nesta página. Agora crie o login que será usado para acessar e editar o cadastro.</Notice>
        <Text label="E-mail de acesso" type="email" value={email} setValue={setEmail} autoComplete="email" />
        <Text label="Crie uma senha forte" type="password" value={password} setValue={setPassword} minLength={PASSWORD_MIN_LENGTH} autoComplete="new-password" />
        <PasswordRequirements password={password} />
        <Text label="Confirme a senha" type="password" value={passwordConfirmation} setValue={setPasswordConfirmation} minLength={PASSWORD_MIN_LENGTH} autoComplete="new-password" />
        <Submit loading={loading}>Criar login e continuar</Submit>
        <Back onClick={() => { setError(""); setStep("form"); }}>Voltar ao cadastro</Back>
      </form>}
      {step === "form" && <form onSubmit={continueFromForm} className="space-y-6">
        <Group title="Você"><Text label="Nome completo" value={form.nome} setValue={(value) => setForm({ ...form, nome: value })} /><Text label="Como prefere ser chamado(a)" required={false} value={form.nome_preferido} setValue={(value) => setForm({ ...form, nome_preferido: value })} /><Text label="Telefone privado com DDD (opcional)" required={false} value={form.telefone} setValue={(value) => setForm({ ...form, telefone: value })} inputMode="tel" help="Este telefone fica privado e, depois de cadastrado, não pode ser substituído." /></Group>
        <Group title="Empresa"><Text label="Nome da empresa" value={form.empresa_nome} setValue={(value) => setForm({ ...form, empresa_nome: value })} /><Area label="O que a empresa faz e quais problemas resolve" value={form.empresa_descricao} setValue={(value) => setForm({ ...form, empresa_descricao: value })} /><Text label="Setor ou categoria" value={form.setor} setValue={(value) => setForm({ ...form, setor: value })} /></Group>
        <Group title="Contatos da empresa"><Text label="Telefone comercial com DDD" required={false} value={form.empresa_telefone} setValue={(value) => setForm({ ...form, empresa_telefone: value })} inputMode="tel" autoComplete="tel" /><Text label="E-mail comercial" required={false} type="email" value={form.empresa_email} setValue={(value) => setForm({ ...form, empresa_email: value })} autoComplete="email" /><Text label="Site" required={false} value={form.site} setValue={(value) => setForm({ ...form, site: value })} /><Text label="Instagram" required={false} value={form.instagram} setValue={(value) => setForm({ ...form, instagram: value })} /><Text label="LinkedIn" required={false} value={form.linkedin} setValue={(value) => setForm({ ...form, linkedin: value })} /></Group>
        <Group title="Serviço principal"><Text label="Nome do serviço" value={form.servico_nome} setValue={(value) => setForm({ ...form, servico_nome: value })} /><Area label="Descrição e problemas que resolve" value={form.servico_descricao} setValue={(value) => setForm({ ...form, servico_descricao: value })} /></Group>
        <Group title="Publicação"><Check checked={form.autoriza_publicacao} setChecked={(value) => setForm({ ...form, autoriza_publicacao: value })}>Autorizo a publicação da empresa e do serviço nas pesquisas da Elo.</Check>{form.autoriza_publicacao && <><Check checked={form.publicar_telefone} setChecked={(value) => setForm({ ...form, publicar_telefone: value })}>Exibir o telefone comercial da empresa nas pesquisas.</Check><Check checked={form.publicar_email} setChecked={(value) => setForm({ ...form, publicar_email: value })}>Exibir o e-mail comercial da empresa nas pesquisas.</Check></>}</Group>
        <Check checked={form.aceita_termos} setChecked={(value) => setForm({ ...form, aceita_termos: value })}>Li e aceito os <Link to="/terms" target="_blank" className="font-black underline">Termos de Uso</Link> e a <Link to="/privacy" target="_blank" className="font-black underline">Política de Privacidade</Link>.</Check>
        <Submit loading={loading}>{authenticated ? "Salvar alterações" : "Salvar e continuar"}</Submit>
      </form>}
      {error && <p className="mt-4 rounded-xl bg-red-50 p-3 text-sm font-semibold text-red-700">{error}</p>}
      {!authenticated && <p className="mt-7 text-center text-sm text-slate-600">Já possui cadastro? <Link to="/entrar" className="font-black text-emerald-800">Entrar</Link></p>}
    </ParticipantShell>
  );
}

function Group({ title, children }: { title: string; children: ReactNode }) { return <fieldset className="space-y-4 rounded-2xl border border-slate-200 p-5"><legend className="px-2 text-sm font-black uppercase tracking-wider text-emerald-900">{title}</legend>{children}</fieldset>; }
function Notice({ children }: { children: ReactNode }) { return <p className="rounded-xl bg-emerald-50 p-4 text-sm leading-6 text-emerald-950">{children}</p>; }
function Text({ label, value, setValue, type = "text", required = true, minLength, inputMode, autoComplete, help }: { label: string; value: string; setValue: (value: string) => void; type?: string; required?: boolean; minLength?: number; inputMode?: "tel" | "numeric"; autoComplete?: string; help?: string }) { return <label className="block text-sm font-bold text-slate-700">{label}<input type={type} required={required} minLength={minLength} inputMode={inputMode} autoComplete={autoComplete} value={value} onChange={(event) => setValue(event.target.value)} className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 font-normal outline-none focus:border-emerald-700" />{help && <span className="mt-1.5 block text-xs font-normal leading-5 text-slate-500">{help}</span>}</label>; }
function Area({ label, value, setValue }: { label: string; value: string; setValue: (value: string) => void }) { return <label className="block text-sm font-bold text-slate-700">{label}<textarea required minLength={15} rows={4} value={value} onChange={(event) => setValue(event.target.value)} className="mt-1.5 w-full resize-y rounded-xl border border-slate-200 px-4 py-3 font-normal outline-none focus:border-emerald-700" /></label>; }
function Check({ checked, setChecked, children }: { checked: boolean; setChecked: (value: boolean) => void; children: ReactNode }) { return <label className="flex items-start gap-3 text-sm leading-6 text-slate-700"><input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)} className="mt-1 h-4 w-4 accent-emerald-800" /> <span>{children}</span></label>; }
function Submit({ loading, children }: { loading: boolean; children: string }) { return <button disabled={loading} className="flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-900 px-4 py-3 font-black text-white disabled:opacity-60">{loading && <Loader2 className="animate-spin" size={18} />}{children}</button>; }
function Back({ onClick, children }: { onClick: () => void; children: string }) { return <button type="button" onClick={onClick} className="w-full rounded-xl border border-slate-200 px-4 py-3 text-sm font-black text-slate-600 hover:border-emerald-800 hover:text-emerald-900">{children}</button>; }

function StepIndicator({ step }: { step: Step }) {
  const current = step === "form" ? 1 : 2;
  return <ol aria-label="Etapas do cadastro" className="mb-6 grid grid-cols-2 gap-2 text-center text-xs font-bold">
    {["Cadastro", "Criar login"].map((label, index) => <li key={label} aria-current={current === index + 1 ? "step" : undefined} className={`rounded-lg px-2 py-2 ${current >= index + 1 ? "bg-emerald-900 text-white" : "bg-slate-100 text-slate-500"}`}>{index + 1}. {label}</li>)}
  </ol>;
}

function PasswordRequirements({ password }: { password: string }) {
  const rules = [
    [password.length >= PASSWORD_MIN_LENGTH, `Pelo menos ${PASSWORD_MIN_LENGTH} caracteres`],
    [/[a-z]/.test(password), "Uma letra minúscula"],
    [/[A-Z]/.test(password), "Uma letra maiúscula"],
    [/\d/.test(password), "Um número"],
    [/[^A-Za-z0-9]/.test(password), "Um símbolo"],
  ] as const;
  return <ul aria-label="Requisitos da senha" className="grid gap-1 rounded-xl bg-slate-50 p-3 text-xs sm:grid-cols-2">{rules.map(([valid, label]) => <li key={label} className={valid ? "font-bold text-emerald-800" : "text-slate-500"}>{valid ? "✓" : "○"} {label}</li>)}</ul>;
}

function validateStrongPassword(password: string) {
  if (password.length < PASSWORD_MIN_LENGTH) return `A senha deve ter pelo menos ${PASSWORD_MIN_LENGTH} caracteres.`;
  if (!/[a-z]/.test(password)) return "A senha deve ter pelo menos uma letra minúscula.";
  if (!/[A-Z]/.test(password)) return "A senha deve ter pelo menos uma letra maiúscula.";
  if (!/\d/.test(password)) return "A senha deve ter pelo menos um número.";
  if (!/[^A-Za-z0-9]/.test(password)) return "A senha deve ter pelo menos um símbolo.";
  return "";
}

