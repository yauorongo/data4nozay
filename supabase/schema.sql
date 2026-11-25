-- =====================================================================
--  Observatoire citoyen — « Vos questions » (Supabase / Postgres)
--  À exécuter UNE fois dans Supabase > SQL Editor > New query > Run.
--  Avant d'exécuter : remplacez VOTRE_EMAIL_ADMIN (tout en bas).
--  Ensuite, exécutez 02-emails-et-reponse-personnelle.sql (emails automatiques).
--  Puis 03-correctif-anti-spam.sql.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Répondants (Data4, mairie, observatoire, admin) ----------
-- Pas de mot de passe : une personne dont l'email figure ici et qui se
-- connecte par lien magique obtient le droit de répondre.
create table if not exists public.responders (
  email      text primary key check (email = lower(email)),
  name       text,
  role       text not null check (role in ('admin','data4','mairie','observatoire')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.is_responder(want_role text default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.responders r
    where r.email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and r.active
      and (want_role is null or r.role = want_role)
  );
$$;

-- ---------- Questions ----------
create table if not exists public.questions (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  question      text not null check (char_length(btrim(question)) between 10 and 1000),
  category      text not null default 'autre'
                check (category in ('bruit','emplois','chaleur','chantier','environnement','circulation','autre')),
  status        text not null default 'pending'
                check (status in ('pending','published','forwarded','answered','rejected')),
  forwarded_to  text,          -- ex. « Data4 », « Mairie de Nozay »
  forwarded_at  timestamptz,
  answer        text,
  answer_by     text check (answer_by in ('data4','mairie','observatoire','autre')),
  answer_source text,          -- lien ou référence (compte rendu, courrier…)
  answered_at   timestamptz,
  ip_hash       text           -- empreinte anonymisée, seulement pour limiter le spam
);
create index if not exists questions_status_idx on public.questions (status, created_at desc);

-- Avant chaque envoi public : on force le statut « en attente » et on
-- limite à 5 questions par heure et par connexion (anti-spam).
create or replace function public.questions_before_insert()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  h text := encode(extensions.digest(
              coalesce(split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1), '')
              || '|observatoire', 'sha256'), 'hex');
begin
  if not public.is_responder() then
    new.status := 'pending';
    new.forwarded_to := null; new.forwarded_at := null;
    new.answer := null; new.answer_by := null; new.answer_source := null; new.answered_at := null;
  end if;
  new.question   := btrim(new.question);
  new.created_at := now();
  new.ip_hash    := h;
  if (select count(*) from public.questions q
        where q.ip_hash = h and q.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Trop de questions envoyées depuis cette connexion. Réessayez dans une heure.';
  end if;
  return new;
end $$;

drop trigger if exists questions_before_insert on public.questions;
create trigger questions_before_insert before insert on public.questions
  for each row execute function public.questions_before_insert();

-- Horodatage automatique quand un répondant transmet ou répond
create or replace function public.questions_before_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.forwarded_to is distinct from old.forwarded_to and new.forwarded_to is not null then
    new.forwarded_at := coalesce(new.forwarded_at, now());
  end if;
  if new.answer is distinct from old.answer and new.answer is not null then
    new.answered_at := now();
    new.status := 'answered';
  end if;
  return new;
end $$;

drop trigger if exists questions_before_update on public.questions;
create trigger questions_before_update before update on public.questions
  for each row execute function public.questions_before_update();

-- ---------- Ce que le public peut voir (aucune donnée technique) ----------
create or replace view public.questions_public as
  select id, created_at, question, category, status,
         forwarded_to, forwarded_at, answer, answer_by, answer_source, answered_at
  from public.questions
  where status in ('published','forwarded','answered');

-- ---------- Sécurité (Row Level Security) ----------
alter table public.questions  enable row level security;
alter table public.responders enable row level security;

revoke all on public.questions, public.responders from anon, authenticated;

-- Public : peut seulement ENVOYER une question (3 champs), rien lire dans la table
grant insert (question, category) on public.questions to anon, authenticated;
drop policy if exists "public peut poser une question" on public.questions;
create policy "public peut poser une question" on public.questions
  for insert to anon, authenticated with check (true);

-- Public : lit la vue des questions publiées
grant select on public.questions_public to anon, authenticated;

-- Répondants : lisent tout, transmettent, répondent, modèrent
grant select, update on public.questions to authenticated;
drop policy if exists "répondants lisent" on public.questions;
create policy "répondants lisent" on public.questions
  for select to authenticated using (public.is_responder());
drop policy if exists "répondants modifient" on public.questions;
create policy "répondants modifient" on public.questions
  for update to authenticated using (public.is_responder()) with check (public.is_responder());
grant delete on public.questions to authenticated;
drop policy if exists "admin supprime" on public.questions;
create policy "admin supprime" on public.questions
  for delete to authenticated using (public.is_responder('admin'));

-- Liste des répondants : visible par les répondants, gérée par les admins
grant select, insert, update, delete on public.responders to authenticated;
drop policy if exists "répondants voient l'équipe" on public.responders;
create policy "répondants voient l'équipe" on public.responders
  for select to authenticated using (public.is_responder());
drop policy if exists "admin gère l'équipe" on public.responders;
create policy "admin gère l'équipe" on public.responders
  for all to authenticated using (public.is_responder('admin')) with check (public.is_responder('admin'));

-- ---------- Premier administrateur : VOUS ----------
-- Remplacez l'adresse ci-dessous par votre email (en minuscules), puis exécutez.
insert into public.responders (email, name, role)
values ('VOTRE_EMAIL_ADMIN', 'Observatoire', 'admin')
on conflict (email) do update set role = 'admin', active = true;
