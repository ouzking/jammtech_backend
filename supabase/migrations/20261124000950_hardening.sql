-- =============================================================================
-- Durcissement des droits d'exécution.
-- Postgres accorde EXECUTE à PUBLIC sur toute nouvelle fonction, et un
-- ALTER DEFAULT PRIVILEGES limité à un schéma ne peut pas retirer ce droit
-- global. On le retire donc explicitement ici, puis on ré-accorde le strict
-- nécessaire.
--
-- ⚠️ Toute nouvelle migration qui crée une fonction doit se terminer par le
--    même schéma : REVOKE ... FROM public, anon ; GRANT ... TO <rôle>.
-- =============================================================================

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon, authenticated;

-- Fonctions d'aide appelées par les politiques RLS (contexte `authenticated`).
grant execute on function
  private.is_trusted_contact_of(uuid, uuid),
  private.has_active_location_window(uuid),
  private.can_view_location(uuid, uuid),
  private.can_receive_topic(text),
  private.is_home_member(uuid),
  private.is_home_owner(uuid),
  private.is_valid_phone(text),
  private.can_view_avatar(text),
  private.normalize_phone(text)
to authenticated;

grant execute on all functions in schema private to service_role;

-- RPC destinées à l'app (ré-affirmées ; la révocation ci-dessus ne touche que
-- public et anon).
grant execute on function
  public.register_push_token(text, public.push_platform, text),
  public.get_security_codes_status(),
  public.set_security_codes(text, text, text),
  public.list_my_sessions(),
  public.revoke_session(uuid),
  public.get_people_i_protect(),
  public.leave_trusted_contact(uuid),
  public.push_location(double precision, double precision, real, timestamptz),
  public.start_location_share(int),
  public.stop_location_share(),
  public.get_live_location(uuid, int),
  public.set_arm_mode(uuid, public.arm_mode, text),
  public.register_device(uuid, public.device_type, text, text),
  public.rotate_device_secret(uuid),
  public.add_home_member(uuid, text, public.home_role),
  public.resolve_alert(uuid, boolean),
  public.resolve_all_alerts(),
  public.nearby_risks(double precision, double precision, int, int),
  public.get_dashboard(uuid),
  public.export_my_data()
to authenticated;
