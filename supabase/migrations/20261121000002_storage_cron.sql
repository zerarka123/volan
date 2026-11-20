-- Buckets de stockage + tâche nocturne. Fonctionne seulement sur Supabase
-- (schémas `storage` et `cron`).

-- Photos d'annonces : publiques en lecture, 1 Mo max (les photos sont
-- compressées dans l'application avant l'envoi).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos', 'listing-photos', true, 1048576, array['image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- Documents de vérification : privés (carte grise, pièce d'identité, registre de commerce).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-docs', 'verification-docs', false, 2097152, array['image/jpeg', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

-- Miniatures des photos refusées (modération) et logos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('moderation-thumbs', 'moderation-thumbs', false, 51200, array['image/jpeg', 'image/webp']),
       ('logos', 'logos', true, 307200, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do nothing;

-- Chaque utilisateur écrit seulement dans son dossier : <bucket>/<user_id>/...
create policy "photos: owner writes" on storage.objects for insert to authenticated
  with check (bucket_id in ('listing-photos', 'logos', 'moderation-thumbs')
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: owner deletes" on storage.objects for delete to authenticated
  using (bucket_id in ('listing-photos', 'logos') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "docs: owner uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs: owner or staff reads" on storage.objects for select to authenticated
  using (bucket_id in ('verification-docs', 'moderation-thumbs')
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff()));

-- Tous les jours à 03:00 UTC (04:00 en Algérie)
create extension if not exists pg_cron;
select cron.schedule('volan-nightly', '0 3 * * *', $$select public.nightly_maintenance()$$);
