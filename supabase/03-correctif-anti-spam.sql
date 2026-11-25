-- =====================================================================
--  Correctif n°3 — anti-spam plus fiable
--  À exécuter dans Supabase > SQL Editor > New query > Run. Rien à modifier.
--
--  • L'adresse du visiteur est lue dans plusieurs en-têtes possibles
--    (cf-connecting-ip, x-real-ip, x-forwarded-for).
--  • Limite : 10 questions par heure et par connexion.
--  • Si l'adresse est introuvable, on n'applique PAS une limite commune à
--    tous les visiteurs (seulement un plafond de sécurité : 100 / heure).
--  • Les modérateurs connectés ne sont jamais limités.
--  • Les tests depuis localhost ne sont pas limités par connexion
--    (seul le plafond de sécurité de 100 / heure s'applique).
--  • En test (localhost), l'email aux modérateurs mène vers localhost.
--  Peut être relancé sans risque.
-- =====================================================================

create or replace function public.questions_before_insert()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  hd  json := coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json);
  ip  text := nullif(btrim(coalesce(hd ->> 'cf-connecting-ip', hd ->> 'x-real-ip',
                                    split_part(coalesce(hd ->> 'x-forwarded-for', ''), ',', 1))), '');
  h   text := case when ip is null then null
                   else encode(extensions.digest(ip || '|observatoire', 'sha256'), 'hex') end;
  -- tests depuis l'ordinateur de développement (http://localhost:…) : pas de limite par connexion
  dev boolean := coalesce(hd ->> 'origin', '') ~ '^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$';
begin
  if not public.is_responder() then
    new.status := 'pending';
    new.forwarded_to := null; new.forwarded_at := null;
    new.answer := null; new.answer_by := null; new.answer_source := null; new.answered_at := null;
    new.answer_emailed_at := null;

    if h is not null and not dev then
      if (select count(*) from public.questions q
            where q.ip_hash = h and q.created_at > now() - interval '1 hour') >= 10 then
        raise exception 'Trop de questions envoyées depuis cette connexion. Réessayez dans une heure.';
      end if;
    elsif (select count(*) from public.questions q where q.created_at > now() - interval '1 hour') >= 100 then
      raise exception 'Beaucoup de questions reçues en ce moment. Réessayez dans une heure.';
    end if;
  end if;

  new.question := btrim(new.question);
  new.email    := nullif(lower(btrim(coalesce(new.email, ''))), '');
  if not coalesce(new.private, false) then new.email := null; end if;
  if new.private and new.email is null then
    raise exception 'Merci d''indiquer un email pour recevoir une réponse personnelle.';
  end if;
  new.created_at := now();
  new.ip_hash    := h;
  return new;
end $$;

-- Email aux modérateurs : en test (question envoyée depuis localhost), le bouton
-- « Répondre » pointe vers http://localhost:…/repondre.html au lieu du site public.
create or replace function public.questions_notify_new()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; s public.mail_settings; body text; base text; org text; dev boolean;
begin
  select * into s from public.mail_settings limit 1;
  org  := coalesce(coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json) ->> 'origin', '');
  dev  := org ~ '^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$';
  base := case when dev then org else coalesce(s.site_url, '') end;
  body := case when dev then '<p style="padding:8px 12px;background:#fff4c2;font-size:13px">🧪 <b>Question de test</b> envoyée depuis ' || org || '</p>' else '' end
       || '<p>Une nouvelle question a été posée sur l''observatoire citoyen'
       || case when new.private then ' — <b>réponse personnelle demandée</b> (elle ne sera pas publiée)' else '' end || ' :</p>'
       || '<p style="padding:12px 16px;background:#f4f4f4;border-left:4px solid #f50500"><b>« ' || public.html_esc(new.question) || ' »</b></p>'
       || '<p>Thème : ' || new.category || '</p>'
       || '<p><a href="' || base || '/repondre.html" style="display:inline-block;background:#f50500;color:#fff;padding:12px 20px;border-radius:999px;text-decoration:none;font-weight:bold">Répondre à la question</a></p>'
       || '<p style="color:#777;font-size:13px">Vous recevez cet email car vous êtes modérateur de l''observatoire citoyen.</p>';
  for r in select email from public.responders where active loop
    perform public.send_mail(r.email, case when dev then '[TEST] ' else '' end || 'Nouvelle question à traiter : '
      || left(new.question, 60) || case when length(new.question) > 60 then '…' else '' end, body);
  end loop;
  return null;
exception when others then
  raise warning 'notification non envoyée : %', sqlerrm;
  return null;
end $$;
revoke all on function public.questions_notify_new() from public, anon, authenticated;

-- Les anciennes empreintes « vides » (adresse introuvable) ne comptent plus
update public.questions
   set ip_hash = null
 where ip_hash = encode(extensions.digest('|observatoire', 'sha256'), 'hex');

-- Diagnostic : questions reçues dans la dernière heure, par connexion
select coalesce(left(ip_hash, 10), '(adresse introuvable)') as connexion, count(*) as questions
  from public.questions
 where created_at > now() - interval '1 hour'
 group by 1 order by 2 desc;
