# Pesquisa de empresários — primeira entrega

Esta entrega implementa somente a pesquisa. O cadastro conversacional e a manutenção pelo próprio empresário permanecem para a etapa seguinte.

## Arquitetura aplicada

- `private.cadastro` continua sendo a fonte oficial da empresa, situação, consentimento e contatos criptografados.
- `private.cadastro_servicos` é o catálogo pesquisável. Cada serviço possui texto de busca, `tsvector`, embedding, situação de indexação e vínculo com o cadastro.
- `private.base_conhecimento` permanece reservada aos documentos institucionais administrados pela Elo.
- O n8n acessa os dados exclusivamente por RPCs públicas S2S; nenhuma tabela privada é consultada diretamente.

## Fluxos

- `Consultar base de conhecimento`: faz a triagem entre consulta institucional e pesquisa de serviços. Quando a solicitação estiver vaga, pede uma descrição objetiva antes de pesquisar.
- `Pesquisar empresários`: gera o embedding da necessidade, recupera candidatos pelo Supabase, executa o reranking por IA, apresenta os cinco primeiros e guarda os restantes no contexto criptografado da conversa.
- `Importar empresário e indexar serviço`: importa o registro autorizado, gera uma descrição pesquisável estritamente baseada nos dados fornecidos, cria o embedding e conclui a indexação do serviço.

## Recuperação e ranking

1. A RPC `rpc_buscar_candidatos_servicos_s2s` recupera até 30 candidatos publicados e indexados.
2. A recuperação combina busca textual em português e similaridade vetorial por RRF.
3. A categoria é texto livre e participa do documento pesquisável; categorias novas não exigem alteração de código.
4. A IA recebe somente os candidatos recuperados, atribui score de 0 a 100 e justifica a compatibilidade com o pedido.
5. O fluxo mantém apenas resultados com score igual ou superior a 50.
6. Um cadastro aparece uma única vez, representado pelo serviço mais compatível.
7. A ordenação usa score decrescente e, em caso de empate, prioriza o cadastro mais antigo.
8. A resposta inicial apresenta até cinco empresas em mensagens separadas. Os demais resultados são mantidos para `mostrar mais`.

Toda a operação é de Blumenau/SC, portanto cidade e estado não são perguntados nem usados no ranking.

## Formato da indicação

Cada empresa é apresentada em uma mensagem própria contendo:

- nome da empresa;
- resumo somente do serviço compatível com a necessidade atual;
- contatos e redes sociais cuja publicação foi autorizada.

O Claude continua responsável pela redação final, limitado aos candidatos e campos autorizados devolvidos pelo fluxo.

## Carga controlada

Execute o subfluxo `Importar empresário e indexar serviço` pelo n8n com um campo `payload` em JSON. Exemplo fictício:

```json
{
  "p_nome": "Pessoa de teste",
  "p_empresa": "Empresa de teste",
  "p_categoria": "Assistência técnica de eletrodomésticos",
  "p_servico": "Conserto de máquinas de lavar",
  "p_descricao": "Diagnóstico e conserto de lavadoras residenciais.",
  "p_problemas_resolvidos": "Lavadora não liga, não centrifuga ou apresenta vazamento.",
  "p_especialidades": ["máquina de lavar", "lavadora"],
  "p_autoriza_publicacao": true,
  "p_publicar_telefone": false,
  "p_created_at": "2024-01-15T12:00:00Z",
  "p_versao_termo": "carga-controlada-v1"
}
```

O fluxo recusa a carga sem `p_autoriza_publicacao: true`. Para adicionar outro serviço ao mesmo empresário, informe o `p_cadastro_id` devolvido pela primeira carga.

## Segurança

- A sessão do Chatwoot é validada antes das operações.
- As tabelas permanecem no schema `private` com RLS ativa.
- Telefone, e-mail, identificadores de canal e mensagens permanecem criptografados.
- Contatos só retornam quando a autorização específica estiver ativa.
- Cadastros bloqueados, incompletos, desativados, sem consentimento ou com serviço não indexado não aparecem.
