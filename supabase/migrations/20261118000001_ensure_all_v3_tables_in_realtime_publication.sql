-- Osigurava da SVE public.v3_* tabele budu u supabase_realtime publikaciji.
-- Do sada je većina tabela (15 od 21) bila dodata u publikaciju ručno na živoj
-- bazi, pa bi `supabase db reset` / rebuild stacka tiho slomio realtime za njih.
-- Idempotentno: preskače tabele koje su već u publikaciji.
do $$
declare
  t text;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname like 'v3\_%' escape '\'
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
