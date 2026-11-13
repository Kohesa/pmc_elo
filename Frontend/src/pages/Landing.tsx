import { useEffect } from "react";
import { Link } from "react-router-dom";
import EloAnimatedBackground from "../components/EloAnimatedBackground";

const steps = [
  {
    number: "01",
    icon: "/elo-landing/8da07.svg",
    title: "Conte o que você precisa",
    description: "Abra o chat e diga qual produto ou serviço você está procurando.",
  },
  {
    number: "02",
    icon: "/elo-landing/1e49f.svg",
    title: "A Elo encontra",
    description: "Ela busca quem pode ajudar entre as empresas cadastradas na nossa comunidade.",
    featured: true,
  },
  {
    number: "03",
    icon: "/elo-landing/5d35a.svg",
    title: "Faça uma nova conexão",
    description: "Conheça a empresa indicada e dê o próximo passo na sua busca.",
  },
];

export default function Landing() {
  useEffect(() => {
    document.body.classList.add("elo-landing-active");

    return () => {
      document.body.classList.remove("elo-landing-active");
    };
  }, []);

  return (
    <main className="elo-landing">
      <EloAnimatedBackground />

      <header className="elo-landing__header">
        <Link className="connect-brand" to="/" aria-label="Connect — Conectando pessoas, fé e propósitos">
          <span className="connect-brand__wordmark">CONNECT</span>
          <img className="connect-brand__symbol" src="/elo-landing/4a63e.png" alt="" />
          <span className="connect-brand__subtitle">CONECTANDO PESSOAS, FÉ E PROPÓSITOS</span>
        </Link>

        <nav className="elo-landing__nav" aria-label="Acesso">
          <Link className="elo-landing__login" to="/entrar">Login</Link>
          <Link className="elo-landing__register" to="/cadastro">Cadastrar empresa</Link>
        </nav>
      </header>

      <section className="elo-landing__hero" aria-labelledby="elo-title">
        <p className="elo-landing__eyebrow">A Elo conecta</p>
        <h1 id="elo-title">
          O que você precisa
          <br />
          a quem pode ajudar.
        </h1>
      </section>

      <section className="elo-how" aria-labelledby="elo-how-title">
        <h2 id="elo-how-title">COMO FUNCIONA A ELO</h2>
        <ol className="elo-how__steps">
          {steps.map((step) => (
            <li className={`elo-step${step.featured ? " elo-step--featured" : ""}`} key={step.number}>
              <span className="elo-step__number">{step.number}</span>
              <span className="elo-step__icon" aria-hidden="true">
                <img src={step.icon} alt="" />
              </span>
              <h3>{step.title}</h3>
              <p>{step.description}</p>
            </li>
          ))}
        </ol>
      </section>

      <footer className="elo-landing__footer">
        <span>CONNECT · CONECTANDO PESSOAS, FÉ E PROPÓSITOS</span>
        <nav aria-label="Links institucionais">
          <Link to="/terms">Termos</Link>
          <Link to="/privacy">Privacidade</Link>
          <Link to="/login">Administração</Link>
        </nav>
      </footer>

    </main>
  );
}
