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

-- Les anciennes empreintes « vides » (adresse introuvable) ne comptent plus
update public.questions
   set ip_hash = null
 where ip_hash = encode(extensions.digest('|observatoire', 'sha256'), 'hex');

-- Diagnostic : questions reçues dans la dernière heure, par connexion
select coalesce(left(ip_hash, 10), '(adresse introuvable)') as connexion, count(*) as questions
  from public.questions
 where created_at > now() - interval '1 hour'
 group by 1 order by 2 desc;
