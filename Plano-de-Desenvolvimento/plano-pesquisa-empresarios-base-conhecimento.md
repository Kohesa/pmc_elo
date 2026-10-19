# Plano de implementação — Pesquisa de empresários pela base de conhecimento

> **Atualização arquitetural aplicada em 18/10/2026:** a pesquisa empresarial não usa mais projeções em `private.base_conhecimento`. O catálogo pesquisável está em `private.cadastro_servicos`, com texto de busca, índice lexical e embedding próprios. A base de conhecimento permanece exclusivamente institucional. A recuperação híbrida do Supabase produz candidatos; o n8n aplica reranking por IA, corte de 50%, deduplicação por cadastro e paginação. Categoria é texto livre e nenhuma lista fixa ou regra por categoria é mantida no código. Esta decisão substitui, neste documento, as referências abaixo a documentos, chunks ou projeções empresariais na base institucional.

## 1. Objetivo

Implementar a pesquisa conversacional de empresários e serviços na Elo Connect reutilizando a infraestrutura de base de conhecimento, processamento de documentos, chunks e busca híbrida herdada da Koris.

O cadastro continuará sendo a fonte oficial dos dados do empresário. A base de conhecimento armazenará uma projeção pública e pesquisável dos serviços publicados por ele.

O resultado esperado é permitir perguntas naturais como:

- “Preciso de um contador para minha empresa.”
- “Quem pode criar uma identidade visual?”
- “Estou com problemas para organizar meu fluxo de caixa.”
- “Tem alguém que trabalhe com marketing em Blumenau?”

A Elo deverá retornar somente empresários cadastrados, aprovados, ativos e com autorização de publicação.

### 1.1 Escopo da primeira entrega

Esta primeira entrega implementará somente a pesquisa conversacional de empresários e serviços.

Ela inclui:

- estrutura mínima para armazenar os serviços pesquisáveis;
- classificação dos documentos empresariais na base de conhecimento;
- carga controlada dos empresários e serviços usados na pesquisa;
- processamento, chunks, embeddings e índice lexical;
- triagem da intenção `busca_servico`;
- esclarecimento de pesquisas vagas;
- score mínimo de 50%;
- prioridade para os cadastros mais antigos;
- limite inicial de cinco resultados;
- continuidade para visualizar os resultados restantes;
- resposta e envio pelo Chatwoot.

Não fazem parte desta primeira entrega:

- cadastro conversacional do empresário;
- coleta progressiva dos dados pelo Chatwoot;
- alteração do perfil pelo próprio empresário;
- criação, edição ou exclusão de serviços pelo usuário;
- coleta ou revogação de consentimento durante a conversa;
- sincronização disparada automaticamente por uma alteração conversacional.

Essas operações serão implementadas na segunda etapa. O modelo criado agora deverá estar preparado para recebê-las sem reconstruir a pesquisa.

### 1.2 Origem dos dados nesta entrega

Enquanto o cadastro conversacional não estiver implementado, os empresários e serviços serão inseridos por carga controlada no backend, seed de desenvolvimento ou importação autorizada da base existente.

Cada registro carregado deverá possuir explicitamente:

- cadastro associado;
- situação aprovada e ativa;
- serviço e categoria;
- descrição pesquisável;
- autorização de publicação registrada na origem da carga;
- data original do cadastro, usada na prioridade de exibição.

Nenhum perfil deverá ser publicado automaticamente apenas porque já existe em `private.cadastro`.

## 2. Decisões desta etapa

1. `private.cadastro` continuará sendo a fonte oficial da identidade, empresa, contatos, situação e consentimentos do empresário.
2. Os serviços oferecidos serão dados estruturados vinculados ao cadastro.
3. Cada serviço publicado gerará um documento próprio em `private.base_conhecimento`.
4. A base de conhecimento terá conteúdos institucionais e empresariais, separados por tipo e origem.
5. A pesquisa institucional nunca consultará documentos empresariais.
6. A pesquisa de serviços nunca usará documentos institucionais como resultado de indicação.
7. A IA somente apresentará resultados devolvidos pelas RPCs autorizadas.
8. Contatos e demais campos canônicos serão lidos do cadastro no momento da resposta, e não extraídos dos chunks.
9. A leitura pública será feita por RPC. As tabelas do schema `private` não serão expostas diretamente.
10. A alteração e a exclusão de um serviço serão permitidas somente ao cadastro proprietário, identificado pela sessão do Chatwoot.

## 3. Arquitetura final da etapa

```text
Cadastro do empresário
  -> cadastro e serviços no Supabase
  -> consentimento de publicação
  -> documento público por serviço na base de conhecimento
  -> processamento e geração de chunks
  -> embedding e índice lexical

Mensagem recebida pelo Chatwoot
  -> triagem identifica busca_servico
  -> extrai necessidade e filtros
  -> verifica se a necessidade está suficientemente clara
  -> quando estiver vaga, pergunta o problema e salva a busca pendente
  -> combina a resposta seguinte com o contexto da busca
  -> gera embedding da necessidade
  -> RPC pesquisa somente documentos empresariais publicados
  -> RPC recupera os dados públicos oficiais dos cadastros encontrados
  -> IA explica por que cada resultado é relevante
  -> resposta enviada pela conversa original do Chatwoot
```

## 4. Separação dos conteúdos da base de conhecimento

A tabela `private.base_conhecimento` será reutilizada. Não será criado outro mecanismo de RAG.

Cada documento deverá possuir uma classificação explícita:

| Tipo de conteúdo | Proprietário | Finalidade | Visibilidade |
| --- | --- | --- | --- |
| `institucional` | Administração Elo | Responder sobre a Elo, o Connect e o ministério | Pública para consultas da IA |
| `perfil_empresario` | Cadastro do empresário | Contexto geral do empresário e do negócio | Pública quando autorizada |
| `servico_empresario` | Cadastro do empresário | Descrever um serviço, especialidade ou problema resolvido | Pública quando autorizada |

Os documentos administrativos continuarão com `cadastro_id IS NULL`. Documentos empresariais terão `cadastro_id` preenchido e deverão apontar para o serviço de origem quando aplicável.

## 5. Modelo de dados

### 5.1 Cadastro

Manter os campos existentes e acrescentar somente os dados necessários à publicação e à pesquisa:

- nome preferido;
- descrição do negócio;
- setor;
- cidade e estado;
- site;
- perfil ativo;
- cadastro concluído em;
- autorização de publicação;
- autorização de publicação concedida em;
- versão do termo de publicação;
- opções indicando quais contatos podem ser apresentados.

Telefone, e-mail e identificadores do canal permanecem criptografados.

### 5.2 Serviços do empresário

Criar `private.cadastro_servicos` como entidade de negócio vinculada a `private.cadastro`.

Campos mínimos:

- `id`;
- `cadastro_id`;
- nome do serviço;
- descrição;
- problemas que resolve;
- especialidades e termos relacionados;
- categoria ou setor;
- localização de atendimento, quando relevante;
- ativo;
- publicado;
- datas de criação e atualização.

Um cadastro poderá possuir vários serviços. A exclusão do cadastro deverá remover ou despublicar seus serviços e documentos associados.

### 5.3 Projeção na base de conhecimento

Acrescentar à estrutura existente, caso ainda não estejam disponíveis:

- tipo do conteúdo;
- serviço de origem;
- publicado;
- publicado em;
- versão do conteúdo;
- origem da criação;
- data da última sincronização.

Deverá existir no máximo uma projeção ativa para cada serviço. Atualizações deverão substituir logicamente a versão pesquisável anterior, evitando resultados duplicados.

## 6. Regras de publicação

Um serviço poderá aparecer na pesquisa somente quando:

1. o cadastro estiver concluído;
2. o cadastro estiver com status `aprovado`;
3. o perfil estiver ativo;
4. o consentimento de publicação estiver vigente;
5. o serviço estiver ativo e publicado;
6. o documento correspondente estiver processado e indexado.

Revogar o consentimento, bloquear o cadastro ou despublicar o serviço deverá retirá-lo imediatamente das novas pesquisas. A remoção física dos chunks poderá ocorrer depois, pois a RPC de busca deverá validar novamente o estado do cadastro e do serviço.

## 7. Segurança, RLS e propriedade

### 7.1 Princípios

- Manter RLS ativa em todas as tabelas privadas.
- Não conceder acesso direto a `anon`, `authenticated` ou ao n8n sobre as tabelas privadas.
- Executar operações externas somente por RPCs públicas autorizadas.
- Ativar o contexto da sessão antes de consultar, alterar ou excluir conteúdo do empresário.
- Validar a propriedade pelo hash do identificador Chatwoot armazenado na sessão.
- Não aceitar `cadastro_id` enviado pelo usuário como prova de propriedade.

### 7.2 Comportamento esperado

- Qualquer usuário pode pesquisar documentos empresariais publicados por meio da RPC de pesquisa.
- O empresário pode consultar e alterar somente seus próprios serviços.
- O empresário pode excluir ou despublicar somente seus próprios documentos.
- Documentos institucionais continuam sob administração da Elo.
- Dados privados de outros cadastros não serão retornados pela pesquisa.

## 8. RPCs necessárias

Os nomes finais poderão seguir o padrão já existente, mas deverão cobrir estas operações:

### 8.1 Cadastro e serviços

As RPCs de criação e manutenção pelo próprio empresário pertencem à segunda etapa. Nesta primeira entrega, serão implementadas apenas as operações técnicas necessárias para a carga controlada e a leitura segura dos registros pesquisáveis.

RPCs previstas para a segunda entrega:

- criar ou atualizar o perfil publicável do próprio cadastro;
- listar os serviços do próprio cadastro;
- criar ou atualizar um serviço;
- ativar, desativar, publicar ou despublicar um serviço;
- excluir um serviço do próprio cadastro;
- registrar ou revogar o consentimento de publicação.

### 8.2 Sincronização da base

- obter os dados canônicos necessários para montar o documento;
- criar ou atualizar a projeção do serviço na base de conhecimento;
- marcar o documento para reindexação;
- concluir a publicação somente após o processamento;
- remover ou despublicar a projeção quando o serviço deixar de ser publicável.

### 8.3 Pesquisa

Criar uma RPC S2S específica para empresários, separada da pesquisa institucional. Ela deverá:

- aceitar texto da necessidade, embedding e filtros estruturados;
- pesquisar apenas `perfil_empresario` e `servico_empresario` publicados;
- combinar similaridade semântica, busca lexical e filtros;
- validar novamente status, atividade e consentimento;
- agrupar chunks do mesmo serviço;
- evitar empresários duplicados na mesma resposta;
- devolver somente os campos públicos autorizados.

## 9. Ranking da pesquisa

A composição do score de compatibilidade deverá considerar, nesta ordem de relevância:

1. compatibilidade com o problema informado;
2. compatibilidade com a descrição do serviço;
3. compatibilidade com especialidades;
4. categoria ou setor;
5. correspondência lexical;
6. localização e demais filtros objetivos;
7. qualidade mínima do resultado.

O Supabase deverá calcular um `score_final` normalizado entre `0` e `1`. Somente empresários com `score_final >= 0,50` serão considerados compatíveis e poderão ser apresentados ao usuário.

O score será interno e funcionará como critério de compatibilidade. A IA não precisará mostrar percentuais ao usuário. Os pesos de cada componente deverão ficar centralizados na RPC ou em uma configuração controlada, permitindo ajuste posterior sem alterar o fluxo conversacional.

Depois de eliminar resultados abaixo de 50%, a ordem final de exibição priorizará a antiguidade do cadastro:

1. `cadastro.created_at` em ordem crescente, apresentando primeiro o cadastro mais antigo;
2. maior `score_final`, quando dois registros possuírem a mesma data de cadastro;
3. identificador do cadastro como desempate determinístico.

Essa regra vale entre empresários compatíveis com o serviço pesquisado. Um cadastro antigo com score inferior a 50% continuará fora dos resultados.

Quando vários chunks ou serviços pertencerem ao mesmo empresário:

- o empresário contará apenas uma vez no total de resultados;
- o maior score compatível será usado como referência principal;
- os serviços relacionados poderão ser agrupados na mesma indicação;
- a data de criação será a prioridade da ordenação final;
- a ordenação terá critérios estáveis de desempate para não mudar entre páginas.

Resultados abaixo de 50% não deverão ser apresentados apenas para preencher a resposta. Quando não houver resultado acima desse limite, a Elo deverá informar que não encontrou uma indicação segura e poderá fazer uma pergunta de esclarecimento.

### 9.1 Limite inicial e continuidade

A primeira resposta apresentará no máximo cinco empresários compatíveis, começando pelos cadastros mais antigos.

Quando existirem mais de cinco empresários compatíveis, a resposta deverá:

1. apresentar somente os cinco primeiros;
2. informar quantos empresários adicionais foram encontrados;
3. perguntar se o usuário deseja visualizar os demais.

Exemplo:

> Encontrei mais 8 empresários que também podem ajudar com essa necessidade. Se quiser, posso mostrar os demais.

Se o usuário responder positivamente, pedir para ver mais ou utilizar expressão equivalente, a Elo deverá devolver os resultados restantes da mesma pesquisa, mantendo a ordem original. Caso o volume ultrapasse o limite de uma mensagem do Chatwoot, os resultados poderão ser enviados em blocos sequenciais, sem executar uma nova pesquisa.

### 9.2 Contexto da pesquisa

O estado da pesquisa deverá ser salvo em `conversas_contexto_ia` ou na estrutura de contexto já existente, contendo no mínimo:

- texto e filtros da pesquisa original;
- identificadores dos empresários e serviços encontrados;
- score final e posição de cada resultado;
- identificadores já apresentados;
- quantidade total de empresários compatíveis;
- data de criação e expiração do contexto.

Esse contexto permitirá reconhecer mensagens como “sim”, “mostrar mais”, “quero ver os outros” ou “tem mais alguém?” como continuação da busca anterior.

Antes de apresentar os resultados restantes, o Supabase deverá validar novamente se cada cadastro continua aprovado, ativo e publicado. Perfis despublicados ou bloqueados depois da pesquisa original não poderão ser exibidos.

## 10. Esclarecimento de pesquisas vagas

A Elo deverá avaliar se a mensagem contém informação suficiente antes de gerar embedding e consultar a base. Termos isolados ou ambíguos, como “mecânica”, “advogado”, “marketing” ou “manutenção”, poderão exigir uma pergunta de esclarecimento.

Exemplo esperado:

```text
Usuário: mecânica
Elo: Perfeito. Descreva melhor que tipo de mecânica você procura ou qual problema precisa resolver. Assim consigo indicar o profissional mais adequado.

Usuário: preciso consertar minha máquina de lavar
Elo: Perfeito! Entendi que você procura assistência técnica para máquina de lavar. Encontrei estes profissionais...
```

No exemplo, a Elo não deverá pesquisar imediatamente pela categoria “Mecânica”. A segunda mensagem indica que a necessidade real é assistência técnica de eletrodomésticos.

### 10.1 Estado da busca pendente

Quando precisar de esclarecimento, o fluxo salvará no contexto:

- intenção `busca_servico`;
- termo inicial informado;
- informações que ainda faltam;
- pergunta de esclarecimento realizada;
- quantidade de tentativas de esclarecimento;
- horário de criação e expiração.

A próxima mensagem do usuário será combinada com o termo inicial e o histórico curto para formar a consulta final. Se o usuário mudar de assunto, a busca pendente será descartada.

### 10.2 Regras da conversa de esclarecimento

- Fazer uma pergunta objetiva por vez.
- Priorizar o problema, o equipamento, o serviço desejado ou o resultado esperado.
- Não executar a pesquisa antes de obter contexto suficiente.
- Limitar o esclarecimento a no máximo duas perguntas.
- Se o usuário não quiser detalhar, permitir uma busca ampla pela categoria informada.
- Não obrigar o usuário a conhecer o nome técnico da categoria.
- Mapear a necessidade esclarecida para categorias e aliases controlados pela Elo.
- Gerar embedding e consumir a pesquisa somente depois do refinamento.

## 11. Alterações no n8n

### 11.1 Triagem

Atualizar a triagem para distinguir pelo menos:

- `institucional`;
- `busca_servico`;
- `cadastro`;
- `correcao_cadastro`;
- `status_cadastro`;
- `atendimento_humano`;
- `fora_escopo`.

A triagem apenas classifica e extrai dados. Para `busca_servico`, também deverá informar se a pesquisa precisa de esclarecimento, quais informações faltam e se a mensagem atual continua uma busca pendente.

### 11.2 Subworkflow de cadastro

Este subworkflow pertence à segunda etapa e não será implementado durante a entrega inicial da pesquisa.

Adaptar o cadastro progressivo para:

- coletar o perfil empresarial;
- cadastrar um ou mais serviços;
- perguntar quais dados podem ser publicados;
- registrar o consentimento;
- salvar cada resposta válida imediatamente;
- permitir interrupção e retomada;
- disparar a sincronização somente quando houver conteúdo suficiente.

### 11.3 Subworkflow de sincronização

Criar um subworkflow responsável por:

1. receber o serviço alterado;
2. obter os dados oficiais por RPC;
3. montar o documento público;
4. criar ou atualizar `private.base_conhecimento` por RPC;
5. executar o processamento existente;
6. gerar chunks e embeddings;
7. concluir a indexação;
8. liberar o documento para pesquisa.

O texto poderá reunir nome público, empresa, descrição, serviço, problemas resolvidos, especialidades, setor e localização. Contatos não deverão ser usados como conteúdo livre dos chunks.

### 11.4 Subworkflow de pesquisa de empresários

Criar um fluxo independente de `Consultar base de conhecimento` para evitar mistura com o RAG institucional.

Etapas:

1. receber a mensagem, histórico curto e identidade da sessão;
2. extrair necessidade, categoria, localização e filtros;
3. verificar se a necessidade está suficientemente clara;
4. quando estiver vaga, salvar a busca pendente e retornar uma pergunta de esclarecimento;
5. quando for continuação, combinar a nova mensagem com a busca pendente;
6. gerar o embedding da consulta refinada;
7. autenticar por S2S e ativar a sessão;
8. chamar a RPC de pesquisa de empresários;
9. descartar resultados com score inferior a 50%;
10. agrupar os resultados por empresário;
11. ordenar os compatíveis pelo cadastro mais antigo e aplicar os desempates definidos;
12. salvar o resultado completo no contexto da conversa;
13. selecionar os cinco primeiros para a resposta inicial;
14. receber os dados públicos autorizados;
15. enviar os resultados ao agente especializado;
16. gerar uma resposta curta, explicando a relevância de cada indicação;
17. informar a quantidade restante quando houver mais de cinco resultados;
18. registrar e enviar a resposta pelo Chatwoot.

O subworkflow também deverá possuir uma entrada de continuidade. Quando a triagem identificar um pedido para visualizar mais resultados, ele deverá recuperar o contexto da última pesquisa, validar novamente os perfis e retornar os empresários ainda não apresentados.

### 11.5 Prompt especializado

O agente de pesquisa deverá:

- usar exclusivamente os candidatos recebidos;
- não inventar empresários, serviços ou contatos;
- não completar campos ausentes;
- explicar por que cada resultado atende à necessidade;
- informar claramente quando não houver resultado adequado;
- fazer uma pergunta objetiva quando precisar de mais contexto;
- não usar fontes externas.

A referência atual à planilha `cadastro atualizado` deverá ser removida do prompt.

## 12. Impactos nos fluxos existentes

### `Conversa com IA`

- deixar de consultar sempre a mesma base;
- chamar a rota adequada conforme a triagem;
- manter histórico, registro de tokens, persistência e envio pelo Chatwoot.

### `Consultar base de conhecimento`

- permanecer responsável pelo conteúdo institucional;
- receber filtro obrigatório de tipo institucional;
- não retornar documentos empresariais.

### Processamento de documentos

- continuar atendendo documentos administrativos;
- aceitar também projeções empresariais criadas por RPC autorizada;
- manter o mesmo pipeline de chunks, embeddings e índices;
- conservar a propriedade do documento durante todo o processamento.

### Painel administrativo

- a tela de documentos continuará exibindo e gerenciando somente documentos institucionais;
- documentos empresariais não deverão aparecer como documentos administrativos editáveis;
- a tela de cadastros poderá exibir situação do perfil, quantidade de serviços e estado de publicação, sem permitir alteração administrativa de status nesta versão.

## 13. Consistência e tratamento de falhas

- O serviço continuará salvo mesmo que a indexação falhe.
- Enquanto a indexação estiver pendente ou com erro, ele não aparecerá na pesquisa.
- Uma nova tentativa poderá reprocessar o documento sem criar duplicatas.
- Cada atualização incrementará a versão do conteúdo.
- O término da indexação deverá validar que processou a versão mais recente.
- Falhas deverão ficar registradas com status e mensagem técnica.
- A resposta ao usuário não deverá afirmar que o serviço foi publicado antes da confirmação do Supabase.

## 14. Migração dos dados existentes

Nesta primeira etapa, a publicação dos dados existentes será feita por carga controlada. Para os cadastros atuais:

1. preservar identidade, contatos e histórico;
2. não publicar automaticamente perfis antigos sem consentimento;
3. importar somente registros que já possuam dados mínimos e autorização confirmada na origem;
4. deixar os demais registros fora da pesquisa até a etapa de cadastro e consentimento;
5. executar uma indexação inicial controlada dos serviços publicados.

Respostas de formulários sem autorização específica de publicação podem ser importadas como cadastros privados pela RPC S2S de carga. Telefone, e-mail e respostas integrais do formulário permanecem criptografados; esses registros ficam inativos, sem consentimento de publicação, sem serviços publicados e sem indexação. A autorização para receber atualizações não substitui o consentimento de publicação.

## 15. Ordem de implementação

### Primeira entrega — Pesquisa

### Etapa 1 — Modelo de dados

- ampliar `private.cadastro` com campos de perfil e publicação;
- criar `private.cadastro_servicos`;
- classificar os documentos da base de conhecimento;
- criar constraints, chaves, índices e vínculos;
- adaptar as migrations existentes quando a estrutura ainda não tiver sido publicada.

### Etapa 2 — Segurança e RPCs da pesquisa

- implementar as políticas RLS;
- criar as RPCs técnicas para carga, sincronização e pesquisa;
- permitir leitura somente dos dados publicáveis por meio das RPCs;
- manter as tabelas privadas inacessíveis diretamente;
- adicionar os escopos S2S necessários;
- validar a sessão Chatwoot antes da pesquisa;
- testar que dados privados e registros não publicados não são retornados.

### Etapa 3 — Sincronização e indexação

- implementar a projeção do serviço;
- adaptar o processamento existente;
- criar atualização idempotente;
- tratar alteração, despublicação, revogação e exclusão;
- validar reindexação sem chunks duplicados.

### Etapa 4 — Carga inicial controlada

- preparar o formato de importação ou seed;
- carregar somente empresários autorizados;
- preservar a data original do cadastro;
- gerar um documento por serviço;
- processar e validar os índices;
- confirmar que registros incompletos ou sem autorização ficaram fora da pesquisa.

### Etapa 5 — Pesquisa conversacional

- criar a RPC de busca híbrida;
- criar o subworkflow de pesquisa;
- conectar a rota `busca_servico`;
- implementar a detecção de pesquisa vaga;
- persistir e retomar a busca pendente;
- aplicar filtros e limites mínimos;
- ordenar os resultados compatíveis pela antiguidade do cadastro;
- hidratar os resultados com os dados oficiais permitidos.

### Etapa 6 — Resposta especializada

- configurar o prompt do agente de indicação;
- formatar as recomendações para o Chatwoot;
- tratar esclarecimento e ausência de resultados;
- registrar mensagem, tokens e status de entrega.

### Etapa 7 — Painel e observabilidade

- separar documentos institucionais dos empresariais no painel;
- exibir situação de publicação nos cadastros;
- registrar falhas de indexação;
- disponibilizar reprocessamento autorizado.

### Etapa 8 — Dados de teste e validação

- carregar empresários de categorias diferentes;
- publicar múltiplos serviços para o mesmo cadastro;
- testar sinônimos, problemas e localização;
- testar bloqueio, despublicação e revogação;
- validar o isolamento dos dados privados;
- confirmar que a IA não inventa resultados.

### Segunda entrega — Cadastro e autosserviço

Depois que a pesquisa estiver funcional e validada:

1. implementar o cadastro conversacional progressivo;
2. coletar perfil, serviços e contatos;
3. registrar o consentimento de publicação;
4. permitir interrupção, retomada e correção;
5. permitir ao empresário criar, editar, despublicar e excluir os próprios serviços;
6. disparar automaticamente a sincronização e a reindexação;
7. retirar imediatamente da pesquisa conteúdos despublicados ou com consentimento revogado.

## 16. Cenários mínimos de teste

1. “Preciso de um contador” retorna somente serviços contábeis publicados.
2. “Quero organizar os impostos da empresa” encontra serviços compatíveis mesmo sem a palavra “contador”.
3. “Mecânica” solicita esclarecimento antes de executar a pesquisa.
4. “Preciso consertar minha máquina de lavar” continua a busca anterior e procura assistência técnica adequada.
5. A mudança de assunto descarta uma busca pendente.
6. Depois de duas tentativas de esclarecimento, o fluxo oferece a busca ampla ou atendimento humano.
7. Resultados com score inferior a 50% não aparecem.
8. Entre dois empresários compatíveis, o cadastro mais antigo aparece primeiro mesmo que o mais novo possua score maior.
9. Um cadastro antigo abaixo de 50% não aparece.
10. Uma pesquisa com até cinco empresários apresenta todos os compatíveis.
11. Uma pesquisa com mais de cinco empresários apresenta os cinco primeiros pela regra de antiguidade e informa a quantidade restante.
12. “Mostrar mais” retorna os demais resultados na mesma ordem, sem refazer a pesquisa.
13. Um empresário com vários chunks ou serviços conta apenas uma vez no total.
14. Um perfil despublicado entre a primeira resposta e “mostrar mais” não aparece na continuação.
15. Um perfil sem consentimento não aparece.
16. Um serviço desativado não aparece.
17. Um cadastro bloqueado não aparece.
18. Revogar o consentimento retira o perfil imediatamente.
19. Atualizar uma descrição substitui os chunks antigos.
20. Uma pergunta institucional não retorna empresários.
21. Uma pesquisa de serviço não retorna documentos institucionais.
22. A IA não apresenta contato que não tenha sido autorizado.
23. Eventos repetidos do Chatwoot não duplicam mensagens nem executam a pesquisa novamente.

## 17. Critérios de aceite

Os critérios abaixo se referem à primeira entrega de pesquisa. Os critérios de cadastro e autosserviço serão validados na segunda entrega.

- Os empresários autorizados da carga inicial estão disponíveis para pesquisa.
- Cada serviço publicado possui uma projeção indexada na base de conhecimento.
- A pesquisa funciona por descrição do problema, serviço, especialidade e termos relacionados.
- Pesquisas vagas são esclarecidas antes da consulta à base.
- A resposta seguinte é combinada corretamente com o contexto da busca pendente.
- Somente resultados com score final igual ou superior a 50% são apresentados.
- Entre os resultados compatíveis, o cadastro mais antigo aparece primeiro.
- A primeira resposta contém no máximo cinco empresários, respeitando a ordem de antiguidade.
- A quantidade de empresários restantes é informada corretamente.
- O pedido para visualizar mais recupera os resultados ainda não apresentados da pesquisa anterior.
- Apenas perfis aprovados, ativos, concluídos e autorizados aparecem.
- Os resultados apresentam somente informações autorizadas.
- A remoção ou revogação impede novas indicações imediatamente.
- A base institucional e a base empresarial permanecem logicamente separadas.
- A RLS permanece ativa.
- Nenhum fluxo acessa diretamente tabelas privadas.
- O n8n usa S2S e estabelece a sessão antes das RPCs.
- A resposta volta pela mesma conversa do Chatwoot.
- Não são criados backend Node, SQLite ou uma segunda infraestrutura de RAG.

O cadastro conversacional e a manutenção dos serviços pelo próprio empresário não bloqueiam o aceite desta primeira entrega.

## 18. Fora do escopo desta etapa

- páginas públicas indexáveis pelo Google;
- marketplace, avaliações e notas de empresários;
- pagamento ou destaque patrocinado;
- ordenação comercial de resultados;
- chat direto entre usuários fora do Chatwoot;
- upload de documentos por empresários;
- alteração administrativa de status pelo painel;
- recomendação baseada em fontes externas.

Se futuramente for necessário SEO para mecanismos de busca, será criada uma etapa específica para páginas públicas rastreáveis. Os embeddings e chunks desta etapa atendem à pesquisa interna da Elo, mas não tornam o conteúdo indexável por buscadores externos.
