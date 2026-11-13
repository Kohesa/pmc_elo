import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import EloAnimatedBackground from "./EloAnimatedBackground";

export default function ParticipantShell({
  title,
  subtitle,
  children,
  eyebrow = "Área do participante",
  backLabel = "Voltar para a Elo",
}: {
  title: string;
  subtitle: string;
  children: ReactNode;
  eyebrow?: string;
  backLabel?: string;
}) {
  return (
    <main className="participant-portal">
      <EloAnimatedBackground />

      <header className="participant-portal__header">
        <Link className="connect-brand participant-brand" to="/" aria-label="Connect — Conectando pessoas, fé e propósitos">
          <span className="connect-brand__wordmark">CONNECT</span>
          <img className="connect-brand__symbol" src="/elo-landing/4a63e.png" alt="" />
          <span className="connect-brand__subtitle">CONECTANDO PESSOAS, FÉ E PROPÓSITOS</span>
        </Link>
        <Link to="/" className="participant-portal__back">← {backLabel}</Link>
      </header>

      <div className="participant-portal__content">
        <section className="participant-card">
          <header className="participant-card__heading">
            <p>{eyebrow}</p>
            <h1>{title}</h1>
            <span>{subtitle}</span>
          </header>
          <div className="participant-card__body">{children}</div>
        </section>
      </div>
    </main>
  );
}

