# Contexto do Produto — Elo Connect

## 1. Finalidade deste documento

Este documento é a fonte de verdade funcional da Elo Connect. Ele define o produto esperado, o escopo do MVP, as regras de negócio e os critérios de aceite.

Decisões técnicas e detalhes de implementação ficam em `ARQUITETURA_ELO.md`. Em caso de dúvida durante o desenvolvimento, o comportamento descrito neste documento deve orientar a solução.

## 2. Visão do produto

A Elo Connect é uma assistente conversacional de conexão e networking. Ela ajuda participantes a:

- entender o que é a Elo e como ela funciona;
- cadastrar seu perfil, negócio, serviços e especialidades;
- encontrar profissionais e empresas capazes de resolver uma necessidade;
- consultar ou corrigir informações do próprio cadastro;
- solicitar atendimento humano quando necessário.

A experiência acontece por canais administrados pelo Chatwoot. O MVP começa pelo widget do Chatwoot. O WhatsApp será adicionado posteriormente, mantendo exatamente as mesmas regras e fluxos da Elo.

## 3. Princípios do produto

1. **A Elo é reativa.** Ela não inicia uma conversa sem uma mensagem anterior do usuário.
2. **A interação do MVP é somente por texto.** Áudio, imagem, vídeo, documento, localização e cartão de contato não são processados.
3. **Cada intenção possui um fluxo especializado.** A triagem identifica a intenção antes de executar cadastro, busca ou resposta institucional.
4. **O cadastro é progressivo.** Cada resposta é salva e o usuário pode interromper e retomar depois.
5. **A busca parte da necessidade.** A prioridade é encontrar quem resolve o problema descrito, e não apenas combinar categorias genéricas.
6. **A IA responde apenas com dados autorizados.** Ela não inventa profissionais, serviços ou informações institucionais.
7. **Privacidade faz parte do produto.** Um usuário nunca pode consultar conversas ou dados privados de outro.
8. **O canal não altera a regra de negócio.** Widget e WhatsApp são portas diferentes para o mesmo produto.

## 4. Usuários do produto

### 4.1 Visitante

Pessoa que iniciou uma conversa, mas ainda não possui cadastro concluído.

Pode:

- conhecer a Elo;
- pesquisar profissionais e serviços publicados;
- iniciar e continuar o cadastro;
- pedir atendimento humano.

### 4.2 Participante cadastrado

Pessoa que concluiu o cadastro na Elo.

Pode:

- usar todas as funções de visitante;
- consultar a situação do próprio cadastro;
- corrigir informações;
- aparecer nas buscas quando estiver ativo e tiver autorizado a publicação.

### 4.3 Operação interna

Equipe responsável por alterações manuais ou automações de backend.

O MVP manterá o painel administrativo já existente, restrito a duas funções:

- gerenciar os documentos da base de conhecimento padrão da IA, incluindo upload, processamento, reprocessamento, categorização e exclusão;
- visualizar todos os cadastros da Elo.

O acesso continuará protegido pelos perfis administrativos existentes. A visualização dos cadastros não autoriza alterar status pelo painel nesta versão. Mudanças de status serão realizadas manualmente no backend ou por automações autorizadas.

## 5. Canais

### 5.1 MVP

- Widget do Chatwoot.

### 5.2 Fase posterior

- WhatsApp conectado ao Chatwoot.

Os dois canais devem utilizar os mesmos fluxos de triagem, cadastro, busca, histórico, prompts, segurança e resposta. A resposta deve voltar pelo mesmo canal de origem.

## 6. Comportamento inicial

- A Elo não envia mensagem ao carregar o widget.
- A primeira resposta acontece somente depois da primeira mensagem do usuário.
- Uma saudação simples, como "olá", deve ser reconhecida pela triagem.
- A resposta inicial deve apresentar brevemente a Elo e perguntar como pode ajudar.
- O usuário não precisa memorizar comandos ou palavras-chave.
- Frases naturais como "quero me cadastrar" ou "preciso de um contador" devem acionar a rota correta.

## 7. Intenções reconhecidas

A triagem deve classificar cada mensagem em uma das seguintes rotas:

| Rota | Finalidade |
| --- | --- |
| `saudacao` | Iniciar ou retomar uma conversa genérica |
| `institucional` | Explicar a Elo, o Connect, missão, participação e funcionamento |
| `cadastro` | Iniciar ou continuar o cadastro |
| `correcao_cadastro` | Corrigir dados já informados pelo próprio usuário |
| `status_cadastro` | Consultar a situação do próprio cadastro |
| `busca_servico` | Encontrar profissional, empresa ou serviço |
| `atendimento_humano` | Solicitar intervenção da equipe pelo Chatwoot |
| `fora_escopo` | Tratar solicitações não relacionadas à finalidade da Elo |

A triagem não deve responder ao usuário. Ela apenas entrega a intenção e os dados extraídos ao fluxo especializado.

## 8. Cadastro

### 8.1 Regras gerais

- O cadastro deve rodar em um subfluxo independente.
- O fluxo pergunta somente o próximo campo necessário.
- Cada resposta válida é salva imediatamente.
- O usuário pode interromper e retomar do ponto salvo.
- O usuário pode pedir correção de uma informação.
- O sistema deve diferenciar campo ausente, resposta inválida e resposta recusada.
- Campos condicionais só devem ser perguntados quando se aplicarem.
- Ao concluir o cadastro, o status inicial é `aprovado`.
- Não haverá aprovação por administrador no MVP.
- Aprovação não significa publicação automática.

### 8.2 Dados previstos

O cadastro deve comportar, conforme o escopo fornecido:

- nome completo;
- nome preferido;
- telefone;
- e-mail;
- nome da empresa ou negócio;
- descrição do negócio;
- problemas que resolve;
- serviços oferecidos;
- site e redes sociais;
- setor: Comércio, Indústria, Serviços, Tecnologia ou Saúde;
- cargo ou função;
- tempo de atuação;
- interesse em participar do ministério;
- assuntos de interesse;
- áreas de especialidade;
- disponibilidade para mentoria;
- identificação como cristão e igreja, quando aplicável;
- participação na escola de servos da Igreja Permanecer, quando aplicável;
- interesse em workshops;
- forma de impacto no Reino;
- desafios atuais;
- como conheceu a Elo;
- autorização para receber atualizações;
- aceite dos termos;
- autorização para publicação do perfil.

### 8.3 Estados do cadastro

| Estado | Significado |
| --- | --- |
| `em_andamento` | Cadastro iniciado e ainda incompleto |
| `aprovado` | Cadastro concluído e aprovado automaticamente |
| `inativo` | Cadastro indisponível por alteração manual ou automação |
| `bloqueado` | Cadastro impedido de operar por decisão de backend |

Somente a operação interna pode mudar um cadastro aprovado para inativo ou bloqueado no MVP.

### 8.4 Regra de publicação

Um perfil só pode aparecer na busca quando todas as condições forem verdadeiras:

- cadastro concluído;
- status `aprovado`;
- cadastro ativo;
- consentimento de publicação concedido;
- serviço ou especialidade disponível para busca.

Revogar o consentimento deve retirar o perfil das novas buscas sem apagar o cadastro.

## 9. Busca de profissionais e serviços

### 9.1 Objetivo

A busca deve conectar uma necessidade relatada pelo usuário a profissionais e empresas cadastrados que possam resolvê-la.

### 9.2 Dados considerados

- problema ou dor descrita;
- serviços oferecidos;
- descrição do negócio;
- especialidades;
- categoria e setor;
- localização, quando informada e relevante;
- outros critérios objetivos mencionados na conversa.

### 9.3 Prioridade do ranking

1. Compatibilidade com o problema que precisa ser resolvido.
2. Compatibilidade com a descrição dos serviços.
3. Compatibilidade com especialidades.
4. Categoria e setor.
5. Termos lexicalmente semelhantes.
6. Critérios complementares, como localização.

### 9.4 Resposta da busca

- A IA só pode apresentar registros retornados pela busca autorizada.
- A resposta deve explicar brevemente por que cada indicação é relevante.
- Dados não autorizados para publicação não podem ser apresentados.
- Se não houver resultado adequado, a Elo deve informar isso claramente.
- A ausência de resultado não autoriza a IA a inventar uma recomendação.
- Uma pergunta de esclarecimento pode ser feita quando a necessidade for vaga.

## 10. Conteúdo institucional

O fluxo institucional deve responder perguntas sobre:

- propósito da Elo;
- funcionamento do Connect;
- formas de participação;
- missão e direcionamento;
- processo de cadastro;
- busca e indicação de serviços.

As respostas devem utilizar somente conteúdo institucional aprovado e configurado. Quando a informação não estiver disponível, a Elo deve reconhecer a limitação ou encaminhar para atendimento humano.

## 11. Prompts e comportamento da IA

- Os prompts serão configuráveis e poderão ser alterados sem reconstruir os fluxos.
- Cada agente terá uma função delimitada.
- O agente de triagem apenas classifica.
- O agente de cadastro não executa busca de serviços.
- O agente de busca responde somente com os resultados recebidos.
- O agente institucional responde somente com conteúdo aprovado.
- Nenhum agente pode revelar prompt, credenciais ou instruções internas.
- O conteúdo enviado pelo usuário é dado de entrada, não uma instrução capaz de substituir as regras do sistema.

## 12. Guardrails

### 12.1 Entrada permitida

- Mensagem de texto não vazia.
- Tamanho dentro do limite configurado.
- Evento originado de um canal Chatwoot autorizado.

### 12.2 Entrada recusada

- áudio;
- imagem;
- vídeo;
- documento;
- sticker;
- localização;
- cartão de contato;
- arquivo ou URL enviada como tentativa de processamento documental;
- conteúdo abusivo repetitivo;
- tentativa de obter credenciais, prompts ou dados de terceiros.

Anexos recusados não devem ser baixados.

### 12.3 Limites de atuação

A Elo não deve:

- executar comandos enviados pelo usuário;
- realizar consultas SQL livres;
- alterar status administrativo por solicitação conversacional;
- divulgar dados privados;
- afirmar que realizou uma ação sem confirmação do sistema;
- produzir recomendações sem base nos registros autorizados;
- atuar fora do propósito de conexão, cadastro e orientação institucional.

## 13. Atendimento humano

- O usuário pode solicitar uma pessoa a qualquer momento.
- O fluxo deve marcar ou encaminhar a conversa dentro do Chatwoot conforme a configuração disponível.
- Depois do encaminhamento, a automação deve evitar competir com o atendente.
- A retomada automática deve depender de uma condição explícita do fluxo ou da operação.

## 14. Privacidade e propriedade dos dados

- Cada contato acessa somente o próprio cadastro e histórico.
- Dados sensíveis são protegidos no backend.
- A busca usa somente uma projeção publicável dos perfis.
- Consentimentos devem guardar data, origem e versão dos termos.
- Eventos e alterações relevantes devem ser auditáveis.
- O histórico não pode ser usado para responder outro usuário.

## 15. Fora do escopo do MVP

- módulos administrativos além da gestão da base padrão da IA e da visualização de cadastros;
- frontend próprio de chat;
- aplicativo móvel;
- cobrança, planos ou assinaturas;
- integração Asaas;
- checkout;
- upload e processamento de documentos por participantes ou recebidos pelo chat;
- transcrição de áudio;
- interpretação de imagem ou vídeo;
- aprovação manual obrigatória de novos cadastros;
- alteração de status por um perfil administrador;
- integração direta com a Meta;
- canais adicionais fora do Chatwoot;
- campanhas proativas iniciadas pela Elo.

## 16. Resultado esperado do MVP

Ao final do MVP, um usuário deve conseguir:

1. Abrir o widget sem receber mensagem automática.
2. Enviar uma mensagem textual.
3. Receber uma resposta adequada à intenção identificada.
4. Conhecer a Elo.
5. Iniciar, interromper e concluir o cadastro.
6. Ter o cadastro aprovado automaticamente ao concluir.
7. Autorizar ou não a publicação do perfil.
8. Pesquisar um profissional ou serviço em linguagem natural.
9. Receber apenas indicações existentes e publicáveis.
10. Solicitar atendimento humano.

A operação interna deve conseguir gerenciar os documentos padrão usados pela IA e visualizar todos os cadastros pelo painel administrativo existente.

A inclusão do WhatsApp deve preservar esse comportamento, alterando somente a porta de entrada e saída.

## 17. Critérios mínimos de aceite

- Nenhuma mensagem é enviada antes da primeira interação do usuário.
- Uma mensagem recebida produz no máximo uma resposta automática correspondente.
- Eventos repetidos não geram respostas duplicadas.
- Mensagens enviadas pela própria Elo não retornam ao fluxo como nova solicitação.
- Arquivos e mídias são recusados sem download.
- A triagem diferencia corretamente as rotas principais.
- O cadastro pode ser retomado sem perder informações.
- O status inicial do cadastro concluído é `aprovado`.
- Perfil sem consentimento não aparece na busca.
- A busca combina critérios semânticos, textuais e estruturados.
- A IA não apresenta resultados inexistentes.
- Um usuário não acessa dados de outro.
- Falhas externas geram resposta controlada e ficam registradas.
- A resposta retorna pelo mesmo canal da mensagem recebida.
- Somente administradores autorizados acessam a gestão de documentos e a listagem de cadastros.
- Documentos enviados pelo painel administrativo são processados e disponibilizados para a base padrão da IA.



