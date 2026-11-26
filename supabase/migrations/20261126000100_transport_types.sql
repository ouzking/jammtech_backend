-- =============================================================================
-- Transport — types énumérés (fichier séparé : une valeur ajoutée par
-- ALTER TYPE ne peut pas être utilisée dans la transaction qui l'ajoute).
-- =============================================================================

alter type public.sos_trigger add value if not exists 'trip_watchdog';
alter type public.alert_category add value if not exists 'vehicle';

create type public.trip_status as enum ('active', 'arrived', 'cancelled', 'escalated', 'expired');
create type public.trip_mode as enum ('taxi', 'clando', 'moto', 'public', 'walk', 'car');
create type public.trip_event_type as enum (
  'started', 'checkin_requested', 'checkin_ok', 'checkin_duress',
  'deviation', 'stopped', 'no_signal', 'late', 'extended', 'battery_low',
  'escalated', 'arrived', 'cancelled'
);
create type public.vehicle_type as enum ('car', 'moto', 'truck');
