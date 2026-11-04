import ParticipantShell from "../components/ParticipantShell";

export default function LegalPage({ kind }: { kind: "terms" | "privacy" }) {
  const privacy = kind === "privacy";

  return (
    <ParticipantShell
      eyebrow="Elo Connect"
      title={privacy ? "Política de Privacidade" : "Termos de Uso"}
      subtitle={privacy ? "Como a Elo protege e utiliza os dados necessários para operar a plataforma." : "Regras para utilização responsável dos serviços e canais da Elo Connect."}
    >
      <article className="legal-content">
        <section>
          <h2>{privacy ? "Uso e proteção dos dados" : "Uso da Elo Connect"}</h2>
          <p>{privacy ? "A Elo utiliza os dados informados na conversa para realizar o cadastro, manter o histórico, indicar serviços autorizados e operar o atendimento. Dados privados não são exibidos a outros usuários, e somente informações com consentimento de publicação podem aparecer nas buscas." : "A Elo Connect é uma assistente de conexão, cadastro e indicação de serviços. O usuário deve fornecer informações verdadeiras e autorizar expressamente a publicação dos dados que poderão aparecer nas buscas."}</p>
        </section>
        <section>
          <h2>Contato e solicitações</h2>
          <p>Dúvidas e solicitações relacionadas a dados podem ser encaminhadas à operação da Elo pelo próprio canal de atendimento.</p>
        </section>
      </article>
    </ParticipantShell>
  );
}
