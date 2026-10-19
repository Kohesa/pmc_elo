# Deploy cloud da Elo Connect

Este guia configura o mesmo fluxo de entrega usado como base na Koris, separado em homologação e produção.

## Fluxo de branches

| Branch | GitHub Environment | Destino |
| --- | --- | --- |
| `homolog` | `homolog` | Supabase e n8n de homologação |
| `master` | `production` | Supabase e n8n de produção |

Fluxo de trabalho:

1. criar uma branch `feature/<nome>` a partir de `homolog`;
2. abrir pull request para `homolog`;
3. o workflow `Validate deploy sources` valida migrations e JSONs do n8n;
4. ao fazer merge em `homolog`, o GitHub publica no ambiente de homologação;
5. depois da validação funcional, abrir pull request de `homolog` para `master`;
6. ao fazer merge em `master`, o GitHub publica em produção.

Não use a mesma instância do Supabase ou do n8n nos dois GitHub Environments.

## Workflows do GitHub

### Supabase

Arquivo: `.github/workflows/deploy.yml`

- executa em push para `homolog` ou `master` quando há alteração no Supabase;
- vincula o projeto correspondente ao GitHub Environment;
- executa `supabase db push`;
- publica as Edge Functions quando `supabase/functions/**` ou `supabase/config.toml` muda;
- uma execução manual publica todas as Edge Functions.

### n8n

Arquivo: `.github/workflows/deploy-n8n.yml`

- executa em push para `homolog` ou `master` quando há alteração nos workflows;
- identifica os JSONs alterados em `n8n/workflows`;
- envia esses arquivos ao gerenciador de deploy do n8n;
- usa o header `X-Deployment-Secret` para autenticar a chamada;
- uma execução manual envia todos os workflows.

O script responsável pelo pacote é `n8n/infraestrutura/dispatch-workflow-deployment.mjs`.

## 1. Criar o repositório da Elo no GitHub

O `origin` deste checkout ainda aponta para o repositório da Koris. Antes do primeiro push, crie um repositório privado para a Elo e troque o remoto:

```powershell
git remote rename origin koris-base
git remote add origin https://github.com/Kohesa/elo-connect.git
git remote -v
```

Substitua `Kohesa/elo-connect` pelo nome real criado no GitHub.

Depois que a versão atual estiver revisada e commitada, publique as branches:

```powershell
git branch homolog
git branch master
git push -u origin homolog
git push -u origin master
```

Se essas branches já existirem, não recrie: apenas faça o push da branch correta.

## 2. Criar os projetos Supabase

Crie dois projetos no Supabase:

- `elo-homolog`;
- `elo-production`.

Para cada projeto, anote:

- **Project ref**: identificador do projeto exibido em Project Settings;
- **Database password**: senha do banco definida no projeto.

Crie também um Personal Access Token em **Account > Access Tokens**. Ele pode ser o mesmo nos dois ambientes, desde que pertença a uma conta com acesso aos dois projetos.

## 3. Preparar as instâncias n8n

Use uma instância para homologação e outra para produção. Em cada instância:

1. configure as variáveis descritas em `n8n/chatwoot.env.example`;
2. configure as credenciais do Supabase, Chatwoot e provedor de IA dentro do n8n;
3. copie da Koris o workflow gerenciador de deploy e adapte apenas o ambiente de destino;
4. configure no gerenciador um segredo longo e aleatório;
5. ative o workflow e copie sua URL de produção.

O gerenciador recebe `POST` com este contrato:

```json
{
  "environment": "homolog ou production",
  "ref": "homolog ou master",
  "repository": "organizacao/repositorio",
  "sha": "commit",
  "workflowsDir": "n8n/workflows",
  "workflows": [
    {
      "file": "caminho/do/workflow.json",
      "workflow": {}
    }
  ]
}
```

Ele deve validar `X-Deployment-Secret`, rejeitar o ambiente incorreto e atualizar/importar os workflows recebidos. Credenciais do n8n não devem ser exportadas para o GitHub; elas são cadastradas uma vez em cada instância.

O gerenciador precisa existir antes do primeiro deploy automatizado. Depois disso, os demais workflows passam a ser publicados pelo GitHub.

## 4. Criar os GitHub Environments

No repositório da Elo, abra **Settings > Environments** e crie:

- `homolog`;
- `production`.

Em `homolog`, limite as deployment branches à branch `homolog`.

Em `production`:

- limite as deployment branches à branch `master`;
- adicione um required reviewer, para o deploy de produção depender de aprovação no GitHub.

## 5. Cadastrar os secrets

Cadastre os mesmos nomes em **cada** GitHub Environment. Os valores devem apontar para o ambiente correspondente.

| Secret | Conteúdo |
| --- | --- |
| `SUPABASE_ACCESS_TOKEN` | Personal Access Token do Supabase |
| `SUPABASE_PROJECT_ID` | Project ref do Supabase daquele ambiente |
| `SUPABASE_DB_PASSWORD` | Senha do banco daquele ambiente |
| `N8N_DEPLOYMENT_WEBHOOK_URL` | URL de produção do gerenciador de deploy daquele n8n |
| `N8N_DEPLOYMENT_SECRET` | Mesmo segredo validado pelo gerenciador daquele n8n |

Não cadastre esses valores como Repository Variables e não salve nenhum deles no repositório.

## 6. Proteger as branches

Em **Settings > Branches > Branch protection rules**:

### `homolog`

- exigir pull request antes do merge;
- exigir o status check `Validar JSONs do n8n`;
- exigir o status check `Validar nomes das migrations`.

### `master`

- exigir pull request antes do merge;
- exigir os mesmos status checks;
- bloquear push direto;
- exigir aprovação do pull request.

## 7. Primeiro deploy

1. faça merge da versão preparada em `homolog`;
2. acompanhe **Actions > Deploy Supabase**;
3. acompanhe **Actions > Deploy n8n workflows**;
4. confirme as migrations no Supabase de homologação;
5. confirme a Edge Function `admin-upload-base-conhecimento`;
6. abra o n8n de homologação e associe eventuais credenciais ausentes aos nós importados;
7. ative os workflows de entrada e os subworkflows necessários;
8. configure o AgentBot do Chatwoot com a URL de homologação;
9. depois da validação funcional, faça o pull request de `homolog` para `master`.

Também é possível executar os dois deploys manualmente em **Actions > Run workflow**. A branch selecionada determina o ambiente.

## 8. Dados e segredos que não pertencem às migrations

Depois do primeiro `db push`, configure separadamente em cada Supabase:

- chave `encryption_key` no Vault;
- credencial em `private.credenciais_s2s` para o n8n daquele ambiente;
- `n8n_base_conhecimento_webhook_url` no Vault;
- `n8n_base_conhecimento_auth` no Vault.

O procedimento SQL está em `n8n/CHATWOOT.md`. Use valores diferentes entre homologação e produção.

No n8n, use o mesmo `client_id` e segredo S2S cadastrados no Supabase correspondente. Configure também as variáveis Chatwoot, OpenRouter e as demais integrações daquele ambiente.

## 9. Falhas comuns

- **Secret ... nao configurado**: o secret não existe no GitHub Environment selecionado.
- **Project not found**: `SUPABASE_PROJECT_ID` contém a URL ou o nome; use apenas o project ref.
- **password authentication failed**: `SUPABASE_DB_PASSWORD` não corresponde ao projeto daquele ambiente.
- **n8n deployment webhook failed: 401/403**: o `N8N_DEPLOYMENT_SECRET` difere do segredo do gerenciador.
- **n8n deployment webhook failed: 404**: foi usada a URL de teste ou o workflow gerenciador está inativo; use a URL de produção.
- **Credencial ausente no workflow importado**: associe a credencial criada no n8n daquele ambiente; segredos não são transportados pelo GitHub.
