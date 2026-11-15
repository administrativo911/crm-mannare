-- =====================================================================
--  CRM Mannare | Espaços (parcerias) com bloqueio no banco
--  Rode UMA VEZ no Supabase: SQL Editor > New query > cole tudo > Run.
--  Faça num horário em que ninguém esteja editando o CRM.
--
--  O que este script faz:
--   1. Cria a coluna "espaco" em pm_docs e preenche sozinha a cada gravação
--      (a partir do campo _espaco que o CRM manda em cada documento).
--      Propostas e financeiro também seguem o espaço (parceiro aprova e acompanha).
--   Pode rodar de novo sem problema: o script é seguro para repetir.
--   2. Cria a coluna "espacos" em pm_equipe (quais espaços cada pessoa acessa).
--      Quem já está na equipe hoje fica com {mannare} = acesso a tudo.
--   3. Liga o Row Level Security: cada pessoa só recebe os documentos dos
--      espaços dela. Quem tem "mannare" vê todos os espaços.
--   4. Só sócios da Mannare podem incluir pessoas e mudar acessos.
--   5. Bloqueia acesso sem login (chave anon). O Apps Script precisa usar a
--      chave service_role (veja o LEIA-ME-ESPACOS.txt antes de rodar).
-- =====================================================================

-- 1) coluna espaco em pm_docs ------------------------------------------------
alter table public.pm_docs add column if not exists espaco text not null default 'mannare';
create index if not exists pm_docs_espaco_idx on public.pm_docs (espaco);

create or replace function public.pm_docs_espaco() returns trigger
language plpgsql as $$
begin
  if new.tipo = 'membro' or new.id = 'config:geral' then
    new.espaco := 'comum';                                   -- nomes/fotos da equipe e configurações gerais
  elsif new.id like 'config:%@%' then
    new.espaco := split_part(new.id, '@', 2);                -- cadastros próprios de cada espaço
  elsif new.tipo = 'config' then
    new.espaco := 'mannare';                                 -- cadastros e integrações da Mannare
  else
    new.espaco := coalesce(nullif(new.dados->>'_espaco', ''),
                           case when tg_op = 'UPDATE' then old.espaco else 'mannare' end);
  end if;
  return new;
end $$;

drop trigger if exists pm_docs_espaco on public.pm_docs;
create trigger pm_docs_espaco before insert or update on public.pm_docs
  for each row execute function public.pm_docs_espaco();

-- documentos que já existem
update public.pm_docs set espaco = 'comum' where tipo = 'membro' or id = 'config:geral';

-- 2) acessos por pessoa ------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'pm_equipe' and column_name = 'espacos') then
    alter table public.pm_equipe add column espacos text[] not null default '{}';
    update public.pm_equipe set espacos = '{mannare}';      -- equipe atual continua vendo tudo
  end if;
end $$;

create or replace function public.pm_meus_espacos() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select espacos from public.pm_equipe
                   where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) limit 1), '{}'::text[]);
$$;

create or replace function public.pm_pode(e text) returns boolean
language sql stable security definer set search_path = public as $$
  select cardinality(public.pm_meus_espacos()) > 0
     and (e = 'comum' or 'mannare' = any(public.pm_meus_espacos()) or e = any(public.pm_meus_espacos()));
$$;

create or replace function public.pm_socio_interno() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pm_equipe
                 where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
                   and papel = 'socio' and 'mannare' = any(espacos));
$$;

-- 3) RLS em pm_docs ----------------------------------------------------------
alter table public.pm_docs enable row level security;

drop policy if exists pm_docs_membros   on public.pm_docs;
drop policy if exists pm_docs_esp_sel   on public.pm_docs;
drop policy if exists pm_docs_esp_ins   on public.pm_docs;
drop policy if exists pm_docs_esp_upd   on public.pm_docs;
drop policy if exists pm_docs_esp_del   on public.pm_docs;
drop policy if exists pm_docs_sem_anon  on public.pm_docs;

create policy pm_docs_membros on public.pm_docs for all to authenticated
  using (cardinality(public.pm_meus_espacos()) > 0) with check (cardinality(public.pm_meus_espacos()) > 0);
create policy pm_docs_esp_sel on public.pm_docs as restrictive for select to authenticated using (public.pm_pode(espaco));
create policy pm_docs_esp_ins on public.pm_docs as restrictive for insert to authenticated with check (public.pm_pode(espaco));
create policy pm_docs_esp_upd on public.pm_docs as restrictive for update to authenticated using (public.pm_pode(espaco)) with check (public.pm_pode(espaco));
create policy pm_docs_esp_del on public.pm_docs as restrictive for delete to authenticated using (public.pm_pode(espaco));
create policy pm_docs_sem_anon on public.pm_docs as restrictive for all to anon using (false) with check (false);

-- 4) RLS em pm_equipe --------------------------------------------------------
alter table public.pm_equipe enable row level security;

drop policy if exists pm_equipe_ler       on public.pm_equipe;
drop policy if exists pm_equipe_socio     on public.pm_equipe;
drop policy if exists pm_equipe_ins_socio on public.pm_equipe;
drop policy if exists pm_equipe_upd_socio on public.pm_equipe;
drop policy if exists pm_equipe_del_socio on public.pm_equipe;
drop policy if exists pm_equipe_sem_anon  on public.pm_equipe;

create policy pm_equipe_ler   on public.pm_equipe for select to authenticated using (true);
create policy pm_equipe_socio on public.pm_equipe for all to authenticated using (public.pm_socio_interno()) with check (public.pm_socio_interno());
create policy pm_equipe_ins_socio on public.pm_equipe as restrictive for insert to authenticated with check (public.pm_socio_interno());
create policy pm_equipe_upd_socio on public.pm_equipe as restrictive for update to authenticated using (public.pm_socio_interno()) with check (public.pm_socio_interno());
create policy pm_equipe_del_socio on public.pm_equipe as restrictive for delete to authenticated using (public.pm_socio_interno());
create policy pm_equipe_sem_anon  on public.pm_equipe as restrictive for all to anon using (false) with check (false);

-- 5) conferência -------------------------------------------------------------
-- quantos documentos em cada espaço:
select espaco, count(*) from public.pm_docs group by espaco order by 1;
-- quem acessa o quê:
select email, papel, espacos from public.pm_equipe order by 1;
