CREATE OR REPLACE FUNCTION public.request_jwt_claims()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_claim text;
BEGIN
  v_claim := current_setting('request.jwt.claim', true);

  IF v_claim IS NULL OR btrim(v_claim) = '' THEN
    v_claim := current_setting('request.jwt.claims', true);
  END IF;

  IF v_claim IS NULL OR btrim(v_claim) = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  RETURN v_claim::jsonb;
EXCEPTION
  WHEN others THEN
    RETURN '{}'::jsonb;
END;
$$;


CREATE OR REPLACE FUNCTION public.request_jwt_sub()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT NULLIF(public.request_jwt_claims() ->> 'sub', '')::uuid;
$$;


CREATE OR REPLACE FUNCTION public.is_automation()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT (public.request_jwt_claims() -> 'app_metadata' ->> 'role') = 'automation';
$$;


CREATE OR REPLACE FUNCTION public.is_chatbot()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT (public.request_jwt_claims() -> 'app_metadata' ->> 'role') = 'chatbot';
$$;
