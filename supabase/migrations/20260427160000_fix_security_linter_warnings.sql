-- O event trigger de RLS e interno e nao pode ser chamado pelos papeis da API.

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM anon;
REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM authenticated;
