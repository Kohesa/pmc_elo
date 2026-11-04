import type { ReactNode } from "react";
import { Link } from "react-router-dom";

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
      <img className="participant-portal__emblem" src="/elo-landing/4a63e.png" alt="" aria-hidden="true" />
      <div className="participant-portal__light" aria-hidden="true" />

      <header className="participant-portal__header">
        <Link className="connect-brand participant-brand" to="/" aria-label="Connect — Ministério de Empreendedores">
          <span className="connect-brand__wordmark">CONNECT</span>
          <img className="connect-brand__symbol" src="/elo-landing/4a63e.png" alt="" />
          <span className="connect-brand__subtitle">MINISTÉRIO DE EMPREENDEDORES</span>
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

