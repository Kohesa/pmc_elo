import { useEffect, useRef, useState } from "react";

type ChatwootApi = {
  toggle: (state?: "open" | "close") => void;
};

type ChatwootToggleEvent = CustomEvent<boolean | { isOpen?: boolean; open?: boolean }>;

function getChatwoot() {
  return (window as Window & { $chatwoot?: ChatwootApi }).$chatwoot;
}

export default function EloChatLauncher() {
  const pendingOpen = useRef(false);
  const chatOpenRef = useRef(false);
  const [chatOpen, setChatOpen] = useState(false);

  useEffect(() => {
    const configureWidget = () => {
      const chatwoot = getChatwoot();

      if (pendingOpen.current && chatwoot) {
        pendingOpen.current = false;
        chatwoot.toggle("open");
      }
    };

    const syncWidgetState = (event: Event) => {
      const detail = (event as ChatwootToggleEvent).detail;
      const isOpen = typeof detail === "boolean" ? detail : detail?.isOpen ?? detail?.open;

      if (typeof isOpen === "boolean") {
        chatOpenRef.current = isOpen;
        setChatOpen(isOpen);
      }
    };

    window.addEventListener("chatwoot:ready", configureWidget);
    window.addEventListener("chatwoot:on-widget-toggle", syncWidgetState);
    configureWidget();

    return () => {
      window.removeEventListener("chatwoot:ready", configureWidget);
      window.removeEventListener("chatwoot:on-widget-toggle", syncWidgetState);
    };
  }, []);

  const toggleChat = () => {
    const chatwoot = getChatwoot();
    if (chatwoot) {
      const nextOpen = !chatOpenRef.current;
      chatOpenRef.current = nextOpen;
      setChatOpen(nextOpen);
      chatwoot.toggle(nextOpen ? "open" : "close");
      return;
    }

    pendingOpen.current = true;
  };

  return (
    <div className="elo-chat-launcher">
      <button className="elo-chat-launcher__hint" type="button" onClick={toggleChat}>
        {chatOpen ? "Fechar conversa" : "Precisa de algo? Fale com a Elo."}
      </button>
      <button
        className={`elo-chat-launcher__avatar${chatOpen ? " elo-chat-launcher__avatar--close" : ""}`}
        type="button"
        onClick={toggleChat}
        aria-label={chatOpen ? "Fechar conversa com a Elo" : "Conversar com a Elo"}
        aria-expanded={chatOpen}
      >
        {chatOpen ? <span className="elo-chat-launcher__close-icon" aria-hidden="true" /> : (
          <>
            <img src="/elo-landing/e78a7.png" alt="" />
            <span className="elo-chat-launcher__status" aria-hidden="true" />
          </>
        )}
      </button>
    </div>
  );
}
