-- =====================================================================
--  CRM Mannare | Usuário master
--  Rode no Supabase (SQL Editor > New query > Run) DEPOIS do espacos-supabase.sql.
--  Pode rodar de novo sem problema.
--
--  - Cria o tipo de usuário "master" (pm_equipe.papel = 'master').
--  - Só master (da Mannare) inclui e remove pessoas, muda tipos e acessos.
--    Enquanto não existir nenhum master, os sócios continuam podendo.
--  - Deixa leticia@mannare.com.br como master.
-- =====================================================================

-- 1) libera o valor 'master' se houver uma regra antiga limitando o papel
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.pm_equipe'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%papel%' loop
    execute format('alter table public.pm_equipe drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.pm_equipe drop constraint if exists pm_equipe_papel_valido;
alter table public.pm_equipe add constraint pm_equipe_papel_valido check (papel in ('master', 'socio', 'equipe'));

-- 2) quem pode gerenciar a equipe (usado pelas regras da tabela pm_equipe)
create or replace function public.pm_socio_interno() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pm_equipe e
    where lower(e.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and 'mannare' = any(e.espacos)
      and (e.papel = 'master'
           or (e.papel = 'socio' and not exists (select 1 from public.pm_equipe m where m.papel = 'master')))
  );
$$;

-- 3) primeira master
update public.pm_equipe set papel = 'master' where lower(email) = 'leticia@mannare.com.br';

-- conferência
select email, papel, espacos from public.pm_equipe order by papel, email;
