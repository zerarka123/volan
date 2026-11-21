-- =====================================================================
-- volan — schéma de base (Supabase / PostgreSQL 15+)
-- Tables, contraintes, sécurité (RLS), fonctions RPC, statistiques admin.
-- Principe : léger. Pas de chat (contact par WhatsApp), on ne garde
-- qu'une ligne par clic dans `events`.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type account_type   as enum ('user', 'parts_shop', 'garage', 'tow', 'dealer');
create type staff_role     as enum ('user', 'moderator', 'admin');
create type listing_kind   as enum ('car', 'part');
create type listing_status as enum ('pending', 'active', 'hidden', 'sold', 'expired');
create type fuel_type      as enum ('petrol', 'diesel', 'lpg', 'hybrid', 'electric');
create type gearbox_type   as enum ('manual', 'automatic');
create type part_quality   as enum ('original', 'brand', 'economy', 'used');
create type verif_kind     as enum ('identity', 'car_papers', 'business');
create type verif_status   as enum ('pending', 'approved', 'rejected');
create type request_status as enum ('open', 'closed', 'expired');
create type offer_status   as enum ('sent', 'reserved', 'declined');
create type booking_status as enum ('requested', 'confirmed', 'done', 'cancelled');
create type sos_status     as enum ('open', 'accepted', 'done', 'cancelled');
create type report_target  as enum ('listing', 'user', 'business');
create type report_reason  as enum ('scam', 'fake_price', 'stolen_photos', 'no_response', 'abuse', 'other');
create type report_status  as enum ('open', 'hidden', 'banned', 'dismissed');
create type pro_plan       as enum ('free', 'pro');
create type event_type     as enum ('view', 'detail', 'whatsapp_click', 'call_click', 'phone_reveal',
                                    'search', 'parts_request', 'sos', 'booking', 'photo_rejected');

-- ---------------------------------------------------------------------
-- Référentiel : wilayas (69 depuis la loi 26-06 du 4 avril 2026)
-- ---------------------------------------------------------------------
create table wilayas (
  code    smallint primary key,
  name_ar text not null,
  name_fr text not null
);

-- ---------------------------------------------------------------------
-- Profils (1 ligne par compte auth.users)
-- ---------------------------------------------------------------------
create table profiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  full_name       text not null check (char_length(full_name) between 2 and 80),
  phone           text not null unique check (phone ~ '^\+213[5-7][0-9]{8}$'),
  wilaya_code     smallint references wilayas (code),
  account_type    account_type not null default 'user',
  role            staff_role   not null default 'user',
  is_verified     boolean      not null default false,   -- identité vérifiée
  is_banned       boolean      not null default false,
  created_at      timestamptz  not null default now()
);

-- Vue publique : jamais le numéro de téléphone.
create view public_profiles as
  select id, split_part(full_name, ' ', 1) || coalesce(' ' || left(split_part(full_name, ' ', 2), 1) || '.', '') as display_name,
         wilaya_code, account_type, is_verified, created_at
  from profiles where not is_banned;

-- ---------------------------------------------------------------------
-- Activités pro (magasin de pièces, garage, dépanneur, showroom)
-- ---------------------------------------------------------------------
create table businesses (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references profiles (id) on delete cascade,
  type          account_type not null check (type <> 'user'),
  name          text not null check (char_length(name) between 2 and 80),
  wilaya_code   smallint not null references wilayas (code),
  commune       text,
  lat           double precision,
  lng           double precision,
  services      text[] not null default '{}',
  brands        text[] not null default '{}',
  opens_at      time,
  closes_at     time,
  delivers_all  boolean not null default false,
  is_open       boolean not null default true,     -- interrupteur "ouvert / fermé"
  plan          pro_plan not null default 'free',
  pro_until     date,
  is_verified   boolean not null default false,
  rating_avg    numeric(2,1) not null default 0,
  rating_count  integer not null default 0,
  logo_path     text,
  created_at    timestamptz not null default now()
);
create index businesses_geo on businesses (type, wilaya_code) where is_open;

-- Tarifs affichés (main d'œuvre, dépannage…)
create table business_prices (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses (id) on delete cascade,
  label        text not null,
  duration     text,
  price_dzd    integer not null check (price_dzd >= 0),
  position     smallint not null default 0
);

-- ---------------------------------------------------------------------
-- Annonces (voitures et pièces)
-- ---------------------------------------------------------------------
create table listings (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references profiles (id) on delete cascade,
  business_id     uuid references businesses (id) on delete set null,
  kind            listing_kind not null,
  title           text not null check (char_length(title) between 3 and 90),
  brand           text,
  model           text,
  year            smallint check (year between 1960 and 2100),
  mileage_km      integer check (mileage_km >= 0),
  fuel            fuel_type,
  gearbox         gearbox_type,
  part_quality    part_quality,
  price_dzd       bigint not null check (price_dzd > 0),   -- 168 millions = 1 680 000 DA
  negotiable      boolean not null default true,
  accepts_swap    boolean not null default false,
  wilaya_code     smallint not null references wilayas (code),
  commune         text,
  description     text check (char_length(description) <= 2000),
  status          listing_status not null default 'active',
  is_verified     boolean not null default false,   -- papiers + identité vérifiés
  featured_until  timestamptz,
  views           integer not null default 0,
  whatsapp_clicks integer not null default 0,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '60 days'
);
create index listings_feed on listings (kind, wilaya_code, status, created_at desc);
create index listings_brand on listings (brand, model) where status = 'active';
create index listings_owner on listings (owner_id);

create table listing_photos (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references listings (id) on delete cascade,
  storage_path  text not null,
  position      smallint not null default 0,
  labels        text[] not null default '{}',   -- étiquettes trouvées par le filtre (ML Kit)
  created_at    timestamptz not null default now()
);
create index listing_photos_listing on listing_photos (listing_id, position);

-- Max 10 photos par annonce
create function enforce_photo_limit() returns trigger language plpgsql as $$
begin
  if (select count(*) from listing_photos where listing_id = new.listing_id) >= 10 then
    raise exception 'max_10_photos';
  end if;
  return new;
end $$;
create trigger listing_photos_limit before insert on listing_photos
  for each row execute function enforce_photo_limit();

-- Photos refusées par le filtre (on garde seulement une miniature pour la modération)
create table photo_rejections (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references profiles (id) on delete set null,
  thumb_path  text,                  -- miniature ~10 Ko, effacée après 30 jours
  labels      text[] not null default '{}',
  manual_ok   boolean not null default false,
  reviewed_by uuid references profiles (id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Vérification (documents dans un bucket privé)
-- ---------------------------------------------------------------------
create table verification_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles (id) on delete cascade,
  kind         verif_kind not null,
  business_id  uuid references businesses (id) on delete cascade,
  listing_id   uuid references listings (id) on delete cascade,
  doc_paths    text[] not null check (cardinality(doc_paths) between 1 and 3),
  status       verif_status not null default 'pending',
  reason       text,
  reviewed_by  uuid references profiles (id),
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index verification_pending on verification_requests (created_at) where status = 'pending';

-- ---------------------------------------------------------------------
-- Demandes de pièces et offres des magasins
-- ---------------------------------------------------------------------
create table parts_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles (id) on delete cascade,
  part_name    text not null check (char_length(part_name) between 2 and 120),
  car_brand    text not null,
  car_model    text not null,
  car_year     smallint,
  engine       text,
  photo_path   text,
  wilaya_code  smallint not null references wilayas (code),
  qualities    part_quality[] not null default '{original,brand,economy,used}',
  status       request_status not null default 'open',
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '48 hours'
);
create index parts_requests_open on parts_requests (wilaya_code, created_at desc) where status = 'open';

create table parts_offers (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references parts_requests (id) on delete cascade,
  business_id      uuid not null references businesses (id) on delete cascade,
  price_dzd        integer not null check (price_dzd > 0),
  quality          part_quality not null,
  brand_name       text,
  warranty_months  smallint not null default 0,
  in_stock         boolean not null default true,
  delivers         boolean not null default false,
  status           offer_status not null default 'sent',
  created_at       timestamptz not null default now(),
  unique (request_id, business_id)
);

-- Offre gratuite : 5 offres par jour ; Pro : illimité
create function enforce_offer_quota() returns trigger language plpgsql as $$
declare b businesses;
begin
  select * into b from businesses where id = new.business_id;
  if b.type <> 'parts_shop' then raise exception 'only_parts_shops_can_offer'; end if;
  if b.plan = 'free' or b.pro_until < current_date then
    if (select count(*) from parts_offers
        where business_id = new.business_id and created_at >= date_trunc('day', now())) >= 5 then
      raise exception 'free_plan_daily_limit';
    end if;
  end if;
  return new;
end $$;
create trigger parts_offers_quota before insert on parts_offers
  for each row execute function enforce_offer_quota();

-- ---------------------------------------------------------------------
-- Réservations (garage, lavage, électricien) et SOS
-- ---------------------------------------------------------------------
create table bookings (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles (id) on delete cascade,
  business_id  uuid not null references businesses (id) on delete cascade,
  service      text not null,
  slot         timestamptz not null,
  at_home      boolean not null default false,
  price_dzd    integer,
  status       booking_status not null default 'requested',
  created_at   timestamptz not null default now()
);
create index bookings_business on bookings (business_id, slot);

create table sos_requests (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles (id) on delete cascade,
  problem          text not null,
  lat              double precision not null,
  lng              double precision not null,
  address          text,
  wilaya_code      smallint references wilayas (code),
  status           sos_status not null default 'open',
  tow_business_id  uuid references businesses (id),
  agreed_price_dzd integer,
  created_at       timestamptz not null default now()
);
create index sos_open on sos_requests (wilaya_code, created_at desc) where status = 'open';

-- ---------------------------------------------------------------------
-- "Ma voiture" : rappels et carnet d'entretien
-- ---------------------------------------------------------------------
create table vehicles (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references profiles (id) on delete cascade,
  brand            text not null,
  model            text not null,
  year             smallint,
  engine           text,
  mileage_km       integer,
  insurance_until  date,
  inspection_until date,      -- contrôle technique
  vignette_year    smallint,
  next_oil_km      integer,
  created_at       timestamptz not null default now()
);

create table maintenance_log (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references vehicles (id) on delete cascade,
  item         text not null,
  done_on      date not null,
  cost_dzd     integer,
  business_id  uuid references businesses (id) on delete set null
);

-- ---------------------------------------------------------------------
-- Événements (statistiques). Écriture uniquement via les fonctions RPC.
-- ---------------------------------------------------------------------
create table events (
  id           bigint generated always as identity primary key,
  type         event_type not null,
  user_id      uuid references profiles (id) on delete set null,
  listing_id   uuid references listings (id) on delete set null,
  business_id  uuid references businesses (id) on delete set null,
  target_user  uuid references profiles (id) on delete set null,   -- vendeur contacté
  wilaya_code  smallint,
  meta         jsonb not null default '{}',
  created_at   timestamptz not null default now()
);
create index events_time on events (type, created_at desc);
create index events_contact on events (user_id, target_user) where type in ('whatsapp_click', 'call_click');

-- ---------------------------------------------------------------------
-- Avis : seulement si on a vraiment contacté (clic WhatsApp/appel) ou réservé
-- ---------------------------------------------------------------------
create table reviews (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references profiles (id) on delete cascade,
  business_id  uuid references businesses (id) on delete cascade,
  seller_id    uuid references profiles (id) on delete cascade,
  rating       smallint not null check (rating between 1 and 5),
  comment      text check (char_length(comment) <= 500),
  created_at   timestamptz not null default now(),
  check ((business_id is null) <> (seller_id is null)),
  unique (author_id, business_id),
  unique (author_id, seller_id)
);

create function enforce_real_contact() returns trigger language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  if new.author_id = coalesce(new.seller_id, (select owner_id from businesses where id = new.business_id)) then
    raise exception 'cannot_review_self';
  end if;
  target := coalesce(new.seller_id, (select owner_id from businesses where id = new.business_id));
  if not exists (
       select 1 from events
       where user_id = new.author_id and type in ('whatsapp_click', 'call_click')
         and (target_user = target or business_id = new.business_id)
     ) and not exists (
       select 1 from bookings where user_id = new.author_id and business_id = new.business_id and status = 'done'
     ) then
    raise exception 'review_requires_contact';
  end if;
  return new;
end $$;
create trigger reviews_real_contact before insert on reviews
  for each row execute function enforce_real_contact();

create function refresh_business_rating() returns trigger language plpgsql security definer set search_path = public as $$
declare bid uuid := coalesce(new.business_id, old.business_id);
begin
  if bid is not null then
    update businesses set
      rating_avg   = coalesce((select round(avg(rating)::numeric, 1) from reviews where business_id = bid), 0),
      rating_count = (select count(*) from reviews where business_id = bid)
    where id = bid;
  end if;
  return null;
end $$;
create trigger reviews_rating after insert or update or delete on reviews
  for each row execute function refresh_business_rating();

-- ---------------------------------------------------------------------
-- Signalements, mises en avant, liste d'attente
-- ---------------------------------------------------------------------
create table reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references profiles (id) on delete cascade,
  target_type  report_target not null,
  target_id    uuid not null,
  reason       report_reason not null,
  details      text check (char_length(details) <= 1000),
  status       report_status not null default 'open',
  handled_by   uuid references profiles (id),
  handled_at   timestamptz,
  created_at   timestamptz not null default now(),
  unique (reporter_id, target_type, target_id)
);
create index reports_open on reports (created_at desc) where status = 'open';

create table featured (
  id           uuid primary key default gen_random_uuid(),
  listing_id   uuid references listings (id) on delete cascade,
  business_id  uuid references businesses (id) on delete cascade,
  days         smallint not null check (days in (3, 7, 30)),
  amount_dzd   integer not null default 0,
  starts_at    timestamptz not null default now(),
  ends_at      timestamptz not null,
  active       boolean not null default true,
  created_by   uuid references profiles (id),
  created_at   timestamptz not null default now(),
  check ((listing_id is null) <> (business_id is null))
);

create table feature_waitlist (
  user_id  uuid not null references profiles (id) on delete cascade,
  feature  text not null,                -- ex. 'pre_purchase_inspection'
  created_at timestamptz not null default now(),
  primary key (user_id, feature)
);

-- =====================================================================
-- Fonctions utilitaires
-- =====================================================================
create function is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('moderator', 'admin'));
$$;
create function is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;
create function owns_business(b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from businesses where id = b and owner_id = auth.uid());
$$;

-- Empêche un utilisateur de se donner lui-même un rôle, un badge ou une mise en avant
create function protect_columns() returns trigger language plpgsql as $$
begin
  if is_staff() or auth.uid() is null then return new; end if;   -- staff, ou fonction serveur
  if tg_table_name = 'profiles' then
    new.role := old.role; new.is_verified := old.is_verified; new.is_banned := old.is_banned; new.phone := old.phone;
  elsif tg_table_name = 'listings' then
    new.is_verified := old.is_verified; new.featured_until := old.featured_until;
    new.views := old.views; new.whatsapp_clicks := old.whatsapp_clicks;
    if old.status = 'hidden' then
      new.status := old.status;                       -- masqué par la modération
    elsif new.status not in ('active', 'sold') then
      new.status := old.status;
    elsif old.status = 'expired' and new.status = 'active' then
      new.expires_at := now() + interval '60 days';   -- renouvellement
    end if;
    if new.expires_at > now() + interval '60 days' then new.expires_at := old.expires_at; end if;
  elsif tg_table_name = 'businesses' then
    new.is_verified := old.is_verified; new.plan := old.plan; new.pro_until := old.pro_until;
    new.rating_avg := old.rating_avg; new.rating_count := old.rating_count;
  end if;
  return new;
end $$;
create trigger profiles_protect   before update on profiles   for each row execute function protect_columns();
create trigger listings_protect   before update on listings   for each row execute function protect_columns();
create trigger businesses_protect before update on businesses for each row execute function protect_columns();

-- Un compte banni ne publie plus
create function reject_banned() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from profiles where id = auth.uid() and is_banned) then raise exception 'account_banned'; end if;
  return new;
end $$;
create trigger listings_no_banned before insert on listings for each row execute function reject_banned();
create trigger parts_requests_no_banned before insert on parts_requests for each row execute function reject_banned();

-- =====================================================================
-- RPC publiques
-- =====================================================================

-- Contact WhatsApp/appel : enregistre le clic, renvoie le numéro et le message pré-rempli.
create function contact_listing(p_listing uuid, p_channel text default 'whatsapp')
returns table (phone text, message text)
language plpgsql security definer set search_path = public as $$
declare l listings; p profiles;
begin
  if p_channel not in ('whatsapp', 'call') then raise exception 'bad_channel'; end if;
  select * into l from listings where id = p_listing and status = 'active';
  if not found then raise exception 'listing_not_found'; end if;
  select * into p from profiles where id = l.owner_id;
  insert into events (type, user_id, listing_id, business_id, target_user, wilaya_code)
    values (case when p_channel = 'whatsapp' then 'whatsapp_click' else 'call_click' end::event_type,
            auth.uid(), l.id, l.business_id, l.owner_id, l.wilaya_code);
  if p_channel = 'whatsapp' then
    update listings set whatsapp_clicks = whatsapp_clicks + 1 where id = l.id;
  end if;
  return query select p.phone,
    format('السلام، شفت إعلانك على volan: %s بـ %s دج', l.title, to_char(l.price_dzd, 'FM999G999G999'));
end $$;

create function contact_business(p_business uuid, p_channel text default 'whatsapp')
returns table (phone text, message text)
language plpgsql security definer set search_path = public as $$
declare b businesses; p profiles;
begin
  if p_channel not in ('whatsapp', 'call') then raise exception 'bad_channel'; end if;
  select * into b from businesses where id = p_business;
  if not found then raise exception 'business_not_found'; end if;
  select * into p from profiles where id = b.owner_id and not is_banned;
  if not found then raise exception 'business_not_found'; end if;
  insert into events (type, user_id, business_id, target_user, wilaya_code)
    values (case when p_channel = 'whatsapp' then 'whatsapp_click' else 'call_click' end::event_type,
            auth.uid(), b.id, b.owner_id, b.wilaya_code);
  return query select p.phone, format('السلام، لقيتك على volan (%s).', b.name);
end $$;

-- Statistique légère (vue d'une annonce, recherche…). Les clics passent par contact_*.
create function track(p_type event_type, p_listing uuid default null, p_business uuid default null, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_type in ('whatsapp_click', 'call_click') then raise exception 'use_contact_rpc'; end if;
  insert into events (type, user_id, listing_id, business_id, meta)
    values (p_type, auth.uid(), p_listing, p_business, coalesce(p_meta, '{}'));
  if p_type = 'detail' and p_listing is not null then
    update listings set views = views + 1 where id = p_listing;
  end if;
end $$;

-- =====================================================================
-- RPC administration (vérifient le rôle)
-- =====================================================================
create function admin_review_verification(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v verification_requests;
begin
  if not is_staff() then raise exception 'forbidden'; end if;
  update verification_requests
     set status = case when p_approve then 'approved' else 'rejected' end::verif_status,
         reason = p_reason, reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id and status = 'pending'
  returning * into v;
  if not found then raise exception 'not_pending'; end if;
  if p_approve then
    if v.kind = 'identity'   then update profiles   set is_verified = true where id = v.user_id; end if;
    if v.kind = 'business'   then update businesses set is_verified = true where id = v.business_id; end if;
    if v.kind = 'car_papers' then update listings   set is_verified = true where id = v.listing_id; end if;
  end if;
end $$;

create function admin_handle_report(p_id uuid, p_action report_status)
returns void language plpgsql security definer set search_path = public as $$
declare r reports; target uuid;
begin
  if not is_staff() then raise exception 'forbidden'; end if;
  if p_action = 'open' then raise exception 'bad_action'; end if;
  update reports set status = p_action, handled_by = auth.uid(), handled_at = now()
   where id = p_id returning * into r;
  if not found then raise exception 'not_found'; end if;
  if p_action = 'hidden' and r.target_type = 'listing' then
    update listings set status = 'hidden' where id = r.target_id;
  elsif p_action = 'banned' then
    target := case r.target_type
                when 'user'     then r.target_id
                when 'listing'  then (select owner_id from listings   where id = r.target_id)
                when 'business' then (select owner_id from businesses where id = r.target_id)
              end;
    update profiles set is_banned = true where id = target;
    update listings set status = 'hidden' where owner_id = target and status = 'active';
  end if;
end $$;

create function admin_set_featured(p_listing uuid, p_business uuid, p_days smallint, p_amount integer default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  if not is_staff() then raise exception 'forbidden'; end if;
  insert into featured (listing_id, business_id, days, amount_dzd, ends_at, created_by)
    values (p_listing, p_business, p_days, p_amount, now() + make_interval(days => p_days), auth.uid())
    returning id into fid;
  if p_listing is not null then
    update listings set featured_until = now() + make_interval(days => p_days) where id = p_listing;
  end if;
  return fid;
end $$;

create function admin_toggle_featured(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare f featured;
begin
  if not is_staff() then raise exception 'forbidden'; end if;
  update featured set active = p_active where id = p_id returning * into f;
  if f.listing_id is not null then
    update listings set featured_until = case when p_active then f.ends_at else null end where id = f.listing_id;
  end if;
end $$;

-- Tableau de bord : un seul appel renvoie toutes les cartes
create function admin_stats(p_from timestamptz default now() - interval '14 days', p_to timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not is_staff() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'users',                (select count(*) from profiles),
    'new_users',            (select count(*) from profiles where created_at between p_from and p_to),
    'active_listings',      (select count(*) from listings where status = 'active'),
    'whatsapp_clicks',      (select count(*) from events where type = 'whatsapp_click' and created_at between p_from and p_to),
    'call_clicks',          (select count(*) from events where type = 'call_click'     and created_at between p_from and p_to),
    'details',              (select count(*) from events where type = 'detail'         and created_at between p_from and p_to),
    'views',                (select count(*) from events where type = 'view'           and created_at between p_from and p_to),
    'parts_requests',       (select count(*) from parts_requests where created_at between p_from and p_to),
    'parts_answered_pct',   (select coalesce(round(100.0 * count(*) filter (where exists (select 1 from parts_offers o where o.request_id = r.id)) / nullif(count(*), 0)), 0)
                               from parts_requests r where created_at between p_from and p_to),
    'sos',                  (select count(*) from sos_requests where created_at between p_from and p_to),
    'photos_rejected',      (select count(*) from photo_rejections where created_at between p_from and p_to),
    'pending_verifications',(select count(*) from verification_requests where status = 'pending'),
    'open_reports',         (select count(*) from reports where status = 'open'),
    'pro_subscriptions',    (select count(*) from businesses where plan = 'pro' and pro_until >= current_date),
    'whatsapp_by_day',      (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'clicks', c) order by d), '[]')
                               from (select date_trunc('day', created_at)::date d, count(*) c from events
                                     where type = 'whatsapp_click' and created_at between p_from and p_to group by 1) x),
    'by_wilaya',            (select coalesce(jsonb_agg(jsonb_build_object('wilaya', w, 'clicks', c) order by c desc), '[]')
                               from (select wilaya_code w, count(*) c from events
                                     where type = 'whatsapp_click' and created_at between p_from and p_to group by 1 limit 10) x),
    'top_listings',         (select coalesce(jsonb_agg(t), '[]') from (
                               select l.id, l.title, l.kind, l.wilaya_code, l.views, count(e.id) as clicks, l.is_verified,
                                      (l.featured_until > now()) as featured
                               from listings l join events e on e.listing_id = l.id
                               where e.type = 'whatsapp_click' and e.created_at between p_from and p_to
                               group by l.id order by clicks desc limit 10) t)
  ) into res;
  return res;
end $$;

-- Tâche planifiée (pg_cron) : expirations et nettoyage
create function nightly_maintenance() returns void language plpgsql security definer set search_path = public as $$
begin
  update listings set status = 'expired' where status = 'active' and expires_at < now();
  update listings set featured_until = null where featured_until < now();
  update featured set active = false where active and ends_at < now();
  update parts_requests set status = 'expired' where status = 'open' and expires_at < now();
  delete from photo_rejections where created_at < now() - interval '30 days';
  delete from events where type in ('view', 'search') and created_at < now() - interval '180 days';
end $$;

-- =====================================================================
-- Sécurité ligne par ligne (RLS)
-- =====================================================================
alter table wilayas               enable row level security;
alter table profiles              enable row level security;
alter table businesses            enable row level security;
alter table business_prices       enable row level security;
alter table listings              enable row level security;
alter table listing_photos        enable row level security;
alter table photo_rejections      enable row level security;
alter table verification_requests enable row level security;
alter table parts_requests        enable row level security;
alter table parts_offers          enable row level security;
alter table bookings              enable row level security;
alter table sos_requests          enable row level security;
alter table vehicles              enable row level security;
alter table maintenance_log       enable row level security;
alter table events                enable row level security;
alter table reviews               enable row level security;
alter table reports               enable row level security;
alter table featured              enable row level security;
alter table feature_waitlist      enable row level security;

create policy wilayas_read on wilayas for select using (true);

create policy profiles_self   on profiles for select using (id = auth.uid() or is_staff());
create policy profiles_insert on profiles for insert with check (id = auth.uid());
create policy profiles_update on profiles for update using (id = auth.uid() or is_staff());

create policy businesses_read   on businesses for select using (true);
create policy businesses_insert on businesses for insert with check (owner_id = auth.uid());
create policy businesses_update on businesses for update using (owner_id = auth.uid() or is_staff());
create policy businesses_delete on businesses for delete using (owner_id = auth.uid() or is_staff());

create policy prices_read  on business_prices for select using (true);
create policy prices_write on business_prices for all using (owns_business(business_id)) with check (owns_business(business_id));

create policy listings_read   on listings for select using (status = 'active' or owner_id = auth.uid() or is_staff());
create policy listings_insert on listings for insert with check (owner_id = auth.uid());
create policy listings_update on listings for update using (owner_id = auth.uid() or is_staff());
create policy listings_delete on listings for delete using (owner_id = auth.uid() or is_staff());

create policy photos_read  on listing_photos for select using (
  exists (select 1 from listings l where l.id = listing_id and (l.status = 'active' or l.owner_id = auth.uid() or is_staff())));
create policy photos_write on listing_photos for all using (
  exists (select 1 from listings l where l.id = listing_id and l.owner_id = auth.uid()))
  with check (exists (select 1 from listings l where l.id = listing_id and l.owner_id = auth.uid()));

create policy rejections_insert on photo_rejections for insert with check (user_id = auth.uid());
create policy rejections_staff  on photo_rejections for select using (is_staff());
create policy rejections_update on photo_rejections for update using (is_staff());

create policy verif_own    on verification_requests for select using (user_id = auth.uid() or is_staff());
create policy verif_insert on verification_requests for insert with check (user_id = auth.uid() and status = 'pending');

create policy preq_read on parts_requests for select using (
  user_id = auth.uid() or is_staff()
  or (status = 'open' and exists (select 1 from businesses b where b.owner_id = auth.uid() and b.type = 'parts_shop')));
create policy preq_insert on parts_requests for insert with check (user_id = auth.uid());
create policy preq_update on parts_requests for update using (user_id = auth.uid());

create policy offers_read on parts_offers for select using (
  owns_business(business_id) or is_staff()
  or exists (select 1 from parts_requests r where r.id = request_id and r.user_id = auth.uid()));
create policy offers_insert on parts_offers for insert with check (owns_business(business_id) and status = 'sent');
create policy offers_update on parts_offers for update using (
  owns_business(business_id) or exists (select 1 from parts_requests r where r.id = request_id and r.user_id = auth.uid()));

create policy bookings_read   on bookings for select using (user_id = auth.uid() or owns_business(business_id) or is_staff());
create policy bookings_insert on bookings for insert with check (user_id = auth.uid() and status = 'requested');
create policy bookings_update on bookings for update using (user_id = auth.uid() or owns_business(business_id));

create policy sos_read on sos_requests for select using (
  user_id = auth.uid() or is_staff() or owns_business(tow_business_id)
  or (status = 'open' and exists (select 1 from businesses b where b.owner_id = auth.uid() and b.type = 'tow')));
create policy sos_insert on sos_requests for insert with check (user_id = auth.uid());
create policy sos_update on sos_requests for update using (
  user_id = auth.uid()
  or (status = 'open' and exists (select 1 from businesses b where b.owner_id = auth.uid() and b.type = 'tow'))
  or owns_business(tow_business_id));

create policy vehicles_own on vehicles for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy maint_own on maintenance_log for all
  using (exists (select 1 from vehicles v where v.id = vehicle_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from vehicles v where v.id = vehicle_id and v.owner_id = auth.uid()));

create policy events_staff on events for select using (is_staff());   -- écriture seulement via RPC

create policy reviews_read   on reviews for select using (true);
create policy reviews_insert on reviews for insert with check (author_id = auth.uid());
create policy reviews_delete on reviews for delete using (author_id = auth.uid() or is_staff());

create policy reports_insert on reports for insert with check (reporter_id = auth.uid() and status = 'open');
create policy reports_read   on reports for select using (reporter_id = auth.uid() or is_staff());

create policy featured_read on featured for select using (active or is_staff());

create policy waitlist_own on feature_waitlist for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Droits
grant usage on schema public to anon, authenticated;
grant select on public_profiles, wilayas to anon, authenticated;
grant select on businesses, business_prices, listings, listing_photos, reviews, featured to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on events, wilayas from authenticated;
grant execute on function contact_listing(uuid, text), contact_business(uuid, text),
                         track(event_type, uuid, uuid, jsonb) to anon, authenticated;
grant execute on function admin_review_verification(uuid, boolean, text), admin_handle_report(uuid, report_status),
                         admin_set_featured(uuid, uuid, smallint, integer), admin_toggle_featured(uuid, boolean),
                         admin_stats(timestamptz, timestamptz) to authenticated;
revoke execute on function nightly_maintenance() from public, anon, authenticated;
