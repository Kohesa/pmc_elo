-- Wrapper HTTP sincrono usado exclusivamente pelo processamento administrativo
-- da base de conhecimento. Preserva:
-- - whitelist de dominio;
-- - validacao de status HTTP 2xx;
-- - erro explicito em falha de rede/timeout;
-- - assinatura/contrato da funcao (RETURNS bigint).

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION private.http_post_seguro(
  p_url                  text,
  p_body                 jsonb,
  p_headers              jsonb,
  p_timeout_milliseconds integer DEFAULT 5000
) RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'private', 'public', 'extensions'
AS $$
DECLARE
  v_host        text;
  v_status_code integer;
  v_auth_header text;
  v_whitelist   text[] := ARRAY[
    'host.docker.internal',
    'localhost',
    '127.0.0.1',
    'n8n.kohesa.com.br'
  ];
BEGIN
  IF p_url IS NULL OR btrim(p_url) = '' THEN
    RAISE EXCEPTION 'http_post_seguro: URL nao pode ser nula ou vazia.'
      USING ERRCODE = '22023';
  END IF;

  v_host := lower(substring(p_url from '^https?://([^/:?#]+)'));

  IF v_host IS NULL OR NOT (v_host = ANY(v_whitelist)) THEN
    RAISE EXCEPTION 'Destino HTTP nao autorizado: dominio "%" nao permitido.', COALESCE(v_host, '<invalido>')
      USING ERRCODE = '42501';
  END IF;

  v_auth_header := NULLIF(
    btrim(COALESCE(p_headers ->> 'auth', p_headers ->> 'Authorization', '')),
    ''
  );

  IF v_auth_header IS NULL THEN
    RAISE EXCEPTION 'http_post_seguro: header de autenticacao ausente.'
      USING ERRCODE = '22023';
  END IF;

  -- Timeout por chamada (best effort conforme versao da extensao).
  BEGIN
    EXECUTE 'SELECT extensions.http_set_curlopt($1, $2)'
      USING 'CURLOPT_TIMEOUT_MS', p_timeout_milliseconds::text;
    EXECUTE 'SELECT extensions.http_set_curlopt($1, $2)'
      USING 'CURLOPT_CONNECTTIMEOUT_MS', p_timeout_milliseconds::text;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    EXECUTE $sql$
      SELECT r.status
      FROM extensions.http(
        (
          'POST',
          $1,
          ARRAY[
            ROW('Content-Type', 'application/json')::extensions.http_header,
            ROW('auth', $2)::extensions.http_header
          ],
          'application/json',
          $3
        )::extensions.http_request
      ) AS r
    $sql$
    INTO v_status_code
    USING p_url, v_auth_header, p_body::text;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Nao foi possivel realizar a operacao. Tente novamente.'
      USING DETAIL = 'Falha HTTP sincrona: ' || SQLERRM,
            ERRCODE = '08006';
  END;

  IF v_status_code IS NULL OR v_status_code < 200 OR v_status_code > 299 THEN
    RAISE EXCEPTION 'Nao foi possivel realizar a operacao. Tente novamente.'
      USING DETAIL = 'Webhook retornou HTTP ' || COALESCE(v_status_code::text, 'sem resposta') || '.',
            ERRCODE = 'P0001';
  END IF;

  -- Mantem contrato RETURNS bigint.
  RETURN v_status_code::bigint;
END;
$$;

ALTER FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) OWNER TO postgres;

REVOKE ALL ON FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) FROM anon;
REVOKE ALL ON FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) FROM authenticated;
REVOKE ALL ON FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) FROM service_role;
GRANT EXECUTE ON FUNCTION private.http_post_seguro(text, jsonb, jsonb, integer) TO private_rpc_executor;
