-- =====================================================================
--  Mise à jour n°2 — « Réponse personnelle par email »
--  À exécuter UNE fois dans Supabase > SQL Editor > New query > Run
--  (après schema.sql). Peut être relancé sans risque.
--
--  Une personne peut demander une réponse privée : elle laisse son email,
--  la question n'est JAMAIS publiée sur le site, et l'email est visible
--  uniquement par les répondants connectés (puis effacé après réponse).
-- =====================================================================

alter table public.questions add column if not exists private boolean not null default false;
alter table public.questions add column if not exists email   text;

alter table public.questions drop constraint if exists questions_email_chk;
alter table public.questions add constraint questions_email_chk
  check (email is null or (char_length(email) <= 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));

-- Envoi public : statut forcé « en attente », email nettoyé, anti-spam
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
  new.email      := nullif(lower(btrim(coalesce(new.email, ''))), '');
  if not coalesce(new.private, false) then new.email := null; end if;
  if new.private and new.email is null then
    raise exception 'Merci d''indiquer un email pour recevoir une réponse personnelle.';
  end if;
  new.created_at := now();
  new.ip_hash    := h;
  if (select count(*) from public.questions q
        where q.ip_hash = h and q.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Trop de questions envoyées depuis cette connexion. Réessayez dans une heure.';
  end if;
  return new;
end $$;

-- Le public ne voit jamais les questions privées (ni aucun email)
create or replace view public.questions_public as
  select id, created_at, question, category, status,
         forwarded_to, forwarded_at, answer, answer_by, answer_source, answered_at
  from public.questions
  where status in ('published','forwarded','answered') and not private;

-- Le public peut envoyer : question, thème, choix « privé » et email
revoke insert on public.questions from anon, authenticated;
grant insert (question, category, private, email) on public.questions to anon, authenticated;
