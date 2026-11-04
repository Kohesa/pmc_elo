-- Finaliza o contrato do catalogo: servicos pertencem a empresas, nunca a
-- identidades privadas. Os campos comerciais legados de cadastro permanecem
-- temporariamente somente para compatibilidade das RPCs conversacionais antigas.

GRANT CREATE ON SCHEMA private TO private_rpc_executor;

-- A pesquisa nao precisa e nao pode abrir acesso de leitura ao cadastro privado.
DROP POLICY IF EXISTS cadastro_pesquisa_empresarios ON private.cadastro;

DROP POLICY IF EXISTS cadastro_servicos_operacao_controlada ON private.cadastro_servicos;
CREATE POLICY cadastro_servicos_operacao_controlada
ON private.cadastro_servicos
FOR ALL
TO private_rpc_executor
USING (
  current_setting('app.session_importacao_empresarios', true) = 'true'
  OR current_setting('app.session_importacao_planilha', true) = 'true'
  OR EXISTS (
    SELECT 1
      FROM private.empresas e
      JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
     WHERE e.id = cadastro_servicos.empresa_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
)
WITH CHECK (
  current_setting('app.session_importacao_empresarios', true) = 'true'
  OR current_setting('app.session_importacao_planilha', true) = 'true'
  OR EXISTS (
    SELECT 1
      FROM private.empresas e
      JOIN private.cadastro c ON c.id = e.cadastro_responsavel_id
     WHERE e.id = cadastro_servicos.empresa_id
       AND c.auth_user_id = private.get_session_auth_user_id()
  )
);

DROP INDEX IF EXISTS private.uq_cadastro_servicos_nome_normalizado;
DROP INDEX IF EXISTS private.idx_cadastro_servicos_publicados;

ALTER TABLE private.cadastro_servicos
  DROP COLUMN IF EXISTS cadastro_id;

CREATE INDEX IF NOT EXISTS idx_cadastro_servicos_publicados
  ON private.cadastro_servicos (publicado, ativo, status_indexacao, empresa_id, created_at, id);

COMMENT ON COLUMN private.cadastro.empresa IS
  'DEPRECIADO: mantido apenas para compatibilidade temporaria. A fonte oficial e private.empresas.nome.';
COMMENT ON COLUMN private.cadastro.descricao_negocio IS
  'DEPRECIADO: mantido apenas para compatibilidade temporaria. A fonte oficial e private.empresas.descricao_negocio.';
COMMENT ON COLUMN private.cadastro.site IS
  'DEPRECIADO: nao usar no RAG. Links publicos ficam em private.empresas.links_publicos.';

REVOKE CREATE ON SCHEMA private FROM private_rpc_executor;
