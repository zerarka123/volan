-- Tests des règles métier et de sécurité. Lancer sur une base de test :
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/rules_test.sql
-- Chaque bloc lève une exception si une règle est cassée.
begin;
insert into auth.users values ('00000000-0000-0000-0000-00000000000a'),('00000000-0000-0000-0000-00000000000b'),
                              ('00000000-0000-0000-0000-00000000000c'),('00000000-0000-0000-0000-00000000000d');
insert into profiles (id, full_name, phone, wilaya_code, account_type, role) values
 ('00000000-0000-0000-0000-00000000000a','كريم مزيان','+213661234567',16,'user','user'),
 ('00000000-0000-0000-0000-00000000000b','نسيم قادري','+213551234567',9,'user','user'),
 ('00000000-0000-0000-0000-00000000000c','سمير بن علي','+213771234567',16,'parts_shop','user'),
 ('00000000-0000-0000-0000-00000000000d','أمين مدير','+213662222222',16,'user','admin');
insert into businesses (id, owner_id, type, name, wilaya_code) values
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c','parts_shop','Pièces El Harrach',16);

create function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true); $$;

-- 1) Le vendeur publie ; il ne peut pas se mettre "vérifié" ni "mis en avant"
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into listings (id, owner_id, kind, title, brand, model, year, price_dzd, wilaya_code)
  values ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','car','Renault Symbol 2019','Renault','Symbol',2019,1680000,16);
update listings set is_verified = true, featured_until = now() + interval '1 year', whatsapp_clicks = 999
  where id = '20000000-0000-0000-0000-000000000001';
do $$ begin
  if (select is_verified or featured_until is not null or whatsapp_clicks <> 0 from listings
      where id = '20000000-0000-0000-0000-000000000001') then raise exception 'FAIL 1: protected columns'; end if; end $$;

-- 2) Un acheteur ne voit pas le téléphone du vendeur dans profiles
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin
  if exists (select 1 from profiles where id = '00000000-0000-0000-0000-00000000000a') then
    raise exception 'FAIL 2: phone leak'; end if; end $$;

-- 3) Avis refusé sans contact réel
do $$ begin
  begin
    insert into reviews (author_id, seller_id, rating) values
      ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a',5);
    raise exception 'FAIL 3: review without contact accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL%' then raise; end if;
  end; end $$;

-- 4) Clic WhatsApp : renvoie numéro + message, compte le clic, puis l'avis passe
do $$ declare r record; begin
  select * into r from contact_listing('20000000-0000-0000-0000-000000000001','whatsapp');
  if r.phone <> '+213661234567' or r.message not like '%volan%' then raise exception 'FAIL 4a: contact rpc'; end if; end $$;
insert into reviews (author_id, seller_id, rating, comment) values
  ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a',5,'السيارة كيما في الصور');

-- 5) Insertion directe dans events interdite
do $$ begin
  begin insert into events (type) values ('whatsapp_click'); raise exception 'FAIL 5: direct event insert';
  exception when insufficient_privilege then null; end; end $$;

-- 6) Demande de pièce ; quota de 5 offres/jour pour le magasin gratuit
insert into parts_requests (id, user_id, part_name, car_brand, car_model, wilaya_code)
  select ('30000000-0000-0000-0000-00000000000' || g)::uuid, '00000000-0000-0000-0000-00000000000b',
         'كيت ديستريبيسيون','Renault','Symbol',16 from generate_series(1,6) g;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
insert into parts_offers (request_id, business_id, price_dzd, quality)
  select ('30000000-0000-0000-0000-00000000000' || g)::uuid, '10000000-0000-0000-0000-000000000001', 14500, 'original'
  from generate_series(1,5) g;
do $$ begin
  begin
    insert into parts_offers (request_id, business_id, price_dzd, quality)
      values ('30000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001', 9800, 'brand');
    raise exception 'FAIL 6: quota not enforced';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end; end $$;

-- 7) Un non-admin n'accède pas aux stats
do $$ begin
  begin perform admin_stats(); raise exception 'FAIL 7: stats open';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end; end $$;

-- 8) Signalement -> l'admin bannit -> annonce masquée
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into reports (id, reporter_id, target_type, target_id, reason) values
  ('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b','listing','20000000-0000-0000-0000-000000000001','scam');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
do $$ declare s jsonb; begin
  s := admin_stats();
  if (s->>'whatsapp_clicks')::int <> 1 or (s->>'open_reports')::int <> 1 then raise exception 'FAIL 8a: stats %', s; end if;
  perform admin_handle_report('40000000-0000-0000-0000-000000000001','banned');
  if (select status from listings where id = '20000000-0000-0000-0000-000000000001') <> 'hidden'
     or not (select is_banned from profiles where id = '00000000-0000-0000-0000-00000000000a') then
    raise exception 'FAIL 8b: ban'; end if; end $$;

-- 9) Le vendeur banni ne peut ni republier ni ré-afficher son annonce
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update listings set status = 'active' where id = '20000000-0000-0000-0000-000000000001';
reset role;
do $$ begin
  if (select status from listings where id = '20000000-0000-0000-0000-000000000001') <> 'hidden' then
    raise exception 'FAIL 9a: unhide'; end if; end $$;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
do $$ begin
  begin insert into listings (owner_id, kind, title, price_dzd, wilaya_code)
          values ('00000000-0000-0000-0000-00000000000a','car','Clio 2016',1500000,16);
        raise exception 'FAIL 9b: banned can post';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end; end $$;

-- 10) Vérification approuvée par l'admin
reset role;
insert into verification_requests (id, user_id, kind, business_id, doc_paths) values
  ('50000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c','business','10000000-0000-0000-0000-000000000001','{c/rc.jpg}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select admin_review_verification('50000000-0000-0000-0000-000000000001', true);
do $$ begin
  if not (select is_verified from businesses where id = '10000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL 10: verification'; end if; end $$;

-- 11) Anonyme : voit les annonces actives, pas les événements
set local role anon;
select pg_temp.as_user('');
do $$ begin
  begin
    if exists (select 1 from events) then raise exception 'FAIL 11: anon sees events'; end if;
  exception when insufficient_privilege then null;   -- encore mieux : aucun accès
  end;
  if not exists (select 1 from wilayas) then raise exception 'FAIL 11b: anon cannot read wilayas'; end if;
end $$;

reset role;
select 'ALL TESTS PASSED' as result;
rollback;

-- =====================================================================
-- Communes
-- =====================================================================
begin;
do $$ begin
  if (select count(*) from wilayas) <> 69 then raise exception 'FAIL C1: wilayas'; end if;
  if (select count(*) from communes) <> 1541 then raise exception 'FAIL C2: communes'; end if;
  if exists (select 1 from wilaya_summary where communes = 0) then raise exception 'FAIL C3: wilaya without commune'; end if;
  if (select communes from wilaya_summary where code = 68) <> 23 then raise exception 'FAIL C4: Bou Saada'; end if;
  if (select wilaya_code from communes where name_fr = 'Bou Saada') <> 68 then raise exception 'FAIL C5: moved commune'; end if;
end $$;
insert into auth.users values ('00000000-0000-0000-0000-0000000000e1');
insert into profiles (id, full_name, phone, wilaya_code) values ('00000000-0000-0000-0000-0000000000e1','تست','+213660000001',42);
do $$ begin
  begin
    insert into listings (owner_id, kind, title, price_dzd, wilaya_code, commune_id)
      values ('00000000-0000-0000-0000-0000000000e1','car','Clio 2016',1500000,42,
              (select id from communes where wilaya_code = 16 limit 1));
    raise exception 'FAIL C6: commune outside wilaya accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
insert into listings (owner_id, kind, title, price_dzd, wilaya_code, commune_id)
  values ('00000000-0000-0000-0000-0000000000e1','car','Clio 2016',1500000,42,
          (select id from communes where wilaya_code = 42 and name_fr ilike 'Cherchell%' limit 1));
select 'COMMUNE TESTS PASSED' as result;
rollback;
