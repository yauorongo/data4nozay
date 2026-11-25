-- =====================================================================
--  Mise à jour n°2 — Réponse personnelle + emails automatiques
--  À exécuter dans Supabase > SQL Editor > New query > Run (après schema.sql).
--  Peut être relancé sans risque.
--
--  • Un citoyen peut demander une réponse personnelle (email) : sa question
--    n'est jamais publiée, son email n'est visible que des modérateurs.
--  • Chaque nouvelle question est envoyée par email aux modérateurs actifs.
--  • Quand un modérateur répond à une question « personnelle », la réponse
--    part automatiquement par email, puis l'adresse est effacée.
--
--  Envoi via Brevo (gratuit, 300 emails/jour). AVANT d'exécuter :
--    1. remplacez VOTRE_EMAIL_EXPEDITEUR ci-dessous (« Réglages ») ;
--    2. enregistrez votre clé API Brevo dans le coffre-fort Supabase avec
--       une requête SÉPARÉE (ne la mettez jamais dans un fichier) :
--         select vault.create_secret('xkeysib-…votre clé…', 'brevo_api_key');
-- =====================================================================

create extension if not exists pg_net;

-- ---------- Réponse personnelle ----------
alter table public.questions add column if not exists private boolean not null default false;
alter table public.questions add column if not exists email text;
alter table public.questions add column if not exists answer_emailed_at timestamptz;
alter table public.questions drop constraint if exists questions_email_chk;
alter table public.questions add constraint questions_email_chk
  check (email is null or (char_length(email) <= 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));

-- ---------- Réglages (non lisibles par le public) ----------
create table if not exists public.mail_settings (
  id           boolean primary key default true check (id),
  sender_email text,
  sender_name  text not null default 'Observatoire citoyen',
  site_url     text not null default 'https://data4nozay.vercel.app'
);
alter table public.mail_settings enable row level security;
revoke all on public.mail_settings from anon, authenticated;
insert into public.mail_settings (id, sender_email, sender_name, site_url)
values (true, 'VOTRE_EMAIL_EXPEDITEUR', 'Observatoire citoyen', 'https://data4nozay.vercel.app')
on conflict (id) do update set sender_email = excluded.sender_email,
  sender_name = excluded.sender_name, site_url = excluded.site_url;

-- ---------- Outils d'envoi (réservés à la base, jamais appelables du site) ----------
create or replace function public.html_esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), E'\n', '<br>');
$$;

create or replace function public.send_mail(to_email text, subject text, html text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare k text; s public.mail_settings;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  select * into s from public.mail_settings limit 1;
  if k is null or s.sender_email is null or position('@' in s.sender_email) = 0 then return false; end if;
  perform net.http_post(
    url     := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body    := jsonb_build_object(
      'sender', jsonb_build_object('name', s.sender_name, 'email', s.sender_email),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', subject,
      'htmlContent', '<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.6;color:#111;max-width:560px">' || html || '</div>'));
  return true;
end $$;
revoke all on function public.send_mail(text, text, text) from public, anon, authenticated;
revoke all on function public.html_esc(text) from public, anon, authenticated;

-- ---------- Envoi public : statut forcé, email nettoyé, anti-spam ----------
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
    new.answer_emailed_at := null;
  end if;
  new.question := btrim(new.question);
  new.email    := nullif(lower(btrim(coalesce(new.email, ''))), '');
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

-- ---------- Nouvelle question → email aux modérateurs ----------
create or replace function public.questions_notify_new()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; s public.mail_settings; body text;
begin
  select * into s from public.mail_settings limit 1;
  body := '<p>Une nouvelle question a été posée sur l''observatoire citoyen'
       || case when new.private then ' — <b>réponse personnelle demandée</b> (elle ne sera pas publiée)' else '' end || ' :</p>'
       || '<p style="padding:12px 16px;background:#f4f4f4;border-left:4px solid #f50500"><b>« ' || public.html_esc(new.question) || ' »</b></p>'
       || '<p>Thème : ' || new.category || '</p>'
       || '<p><a href="' || coalesce(s.site_url, '') || '/repondre.html" style="display:inline-block;background:#f50500;color:#fff;padding:12px 20px;border-radius:999px;text-decoration:none;font-weight:bold">Répondre à la question</a></p>'
       || '<p style="color:#777;font-size:13px">Vous recevez cet email car vous êtes modérateur de l''observatoire citoyen.</p>';
  for r in select email from public.responders where active loop
    perform public.send_mail(r.email, 'Nouvelle question à traiter : ' || left(new.question, 60) || case when length(new.question) > 60 then '…' else '' end, body);
  end loop;
  return null;
exception when others then
  raise warning 'notification non envoyée : %', sqlerrm;  -- ne bloque jamais l'envoi de la question
  return null;
end $$;
revoke all on function public.questions_notify_new() from public, anon, authenticated;

drop trigger if exists questions_notify_new on public.questions;
create trigger questions_notify_new after insert on public.questions
  for each row execute function public.questions_notify_new();

-- ---------- Réponse : horodatage + envoi automatique si « personnelle » ----------
create or replace function public.questions_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if new.forwarded_to is distinct from old.forwarded_to and new.forwarded_to is not null then
    new.forwarded_at := coalesce(new.forwarded_at, now());
  end if;
  if new.answer is distinct from old.answer and new.answer is not null then
    new.answered_at := now();
    new.status := 'answered';
    if new.private and new.email is not null then
      who := case new.answer_by when 'data4' then 'Data4' when 'mairie' then 'la mairie' else 'l''observatoire citoyen' end;
      if public.send_mail(new.email, 'Réponse à votre question — Observatoire citoyen',
           '<p>Bonjour,</p><p>Vous avez posé la question suivante :</p>'
        || '<p style="padding:12px 16px;background:#f4f4f4;border-left:4px solid #999"><i>« ' || public.html_esc(new.question) || ' »</i></p>'
        || '<p><b>Réponse de ' || who || ' :</b></p><p style="padding:12px 16px;background:#eefaf4;border-left:4px solid #00a36e">' || public.html_esc(new.answer) || '</p>'
        || coalesce('<p>Source : ' || public.html_esc(new.answer_source) || '</p>', '')
        || '<p>Cordialement,<br>' || who || '</p>'
        || '<p style="color:#777;font-size:13px">Votre adresse email a été effacée après cet envoi. Merci de ne pas répondre à ce message.</p>') then
        new.answer_emailed_at := now();
        new.email := null;
      else
        raise exception 'L''envoi des emails n''est pas encore configuré (clé Brevo ou expéditeur manquant).';
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.questions_before_update() from public, anon, authenticated;

-- ---------- Le public ne voit jamais les questions personnelles ----------
create or replace view public.questions_public as
  select id, created_at, question, category, status,
         forwarded_to, forwarded_at, answer, answer_by, answer_source, answered_at
  from public.questions
  where status in ('published','forwarded','answered') and not private;

-- ---------- Le public peut envoyer : question, thème, choix « personnel », email ----------
revoke insert on public.questions from anon, authenticated;
grant insert (question, category, private, email) on public.questions to anon, authenticated;

notify pgrst, 'reload schema';
