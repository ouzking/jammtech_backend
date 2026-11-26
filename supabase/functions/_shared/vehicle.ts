// Règles d'alerte des traceurs GPS (fonctions pures, testées unitairement).
// Heures en Africa/Dakar. Aucune commande à distance n'existe : on ne fait
// qu'observer et alerter.
import { dakarMinutes } from "./notify.ts";

export interface TrackerState {
  ignition: boolean | null;
  external_power: boolean | null;
  inside_geofence: boolean | null;
}

export interface VehicleRules {
  allowed_start: string | null; // "06:00:00"
  allowed_end: string | null;
  night_ignition_alert: boolean;
  geofence_alert: boolean;
}

export interface Geofence {
  id: string;
  name: string;
  lat: number;
  lng: number;
  radius_m: number;
}

export interface TrackerUpdate {
  type: string;
  lat?: number;
  lng?: number;
  speed_kmh?: number;
  ignition?: boolean;
  external_power?: boolean;
}

export interface PlannedAlert {
  severity: "critical" | "warning" | "info";
  title: string;
  description: string;
  dedupe: string;
}

const NIGHT_START = 22 * 60;
const NIGHT_END = 6 * 60;

function minutes(t: string): number {
  const [h, m] = t.split(":").map(Number);
  return h * 60 + (m || 0);
}

function within(cur: number, start: number, end: number): boolean {
  return start <= end ? cur >= start && cur < end : cur >= start || cur < end;
}

/** Distance en mètres (haversine). */
export function distanceM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}

export function evaluateTrackerAlerts(
  args: {
    trackerId: string;
    vehicleLabel: string;
    previous: TrackerState;
    update: TrackerUpdate;
    rules: VehicleRules | null;
    geofences: Geofence[];
  },
  now = new Date(),
): { alerts: PlannedAlert[]; insideGeofence: boolean | null } {
  const { trackerId, vehicleLabel, previous, update, rules, geofences } = args;
  const alerts: PlannedAlert[] = [];
  const hour = now.toISOString().slice(0, 13);
  const cur = dakarMinutes(now);
  const moving = (update.speed_kmh ?? 0) > 5;
  const ignitionOn = update.ignition ?? previous.ignition ?? false;

  if (update.external_power === false && previous.external_power !== false) {
    alerts.push({
      severity: "critical",
      title: "Traceur débranché",
      description: `L'alimentation du traceur de ${vehicleLabel} a été coupée.`,
      dedupe: `power:${trackerId}`,
    });
  }

  if (update.type === "shock") {
    alerts.push({
      severity: "warning",
      title: "Choc détecté",
      description: `Le traceur de ${vehicleLabel} signale un choc.`,
      dedupe: `shock:${trackerId}:${hour}`,
    });
  }

  if (
    rules?.night_ignition_alert && update.ignition === true && previous.ignition !== true &&
    within(cur, NIGHT_START, NIGHT_END)
  ) {
    alerts.push({
      severity: "warning",
      title: "Contact moteur la nuit",
      description: `Le moteur de ${vehicleLabel} a été démarré pendant la nuit.`,
      dedupe: `night_ignition:${trackerId}:${hour}`,
    });
  }

  if (
    rules?.allowed_start && rules.allowed_end && (moving || ignitionOn) &&
    !within(cur, minutes(rules.allowed_start), minutes(rules.allowed_end))
  ) {
    alerts.push({
      severity: "critical",
      title: "Mouvement hors des heures autorisées",
      description: `${vehicleLabel} est en mouvement en dehors des heures autorisées.`,
      dedupe: `off_hours:${trackerId}:${hour}`,
    });
  }

  let insideGeofence = previous.inside_geofence;
  if (geofences.length > 0 && update.lat !== undefined && update.lng !== undefined) {
    insideGeofence = geofences.some((g) => distanceM(update.lat!, update.lng!, g.lat, g.lng) <= g.radius_m);
    if (rules?.geofence_alert !== false && previous.inside_geofence === true && !insideGeofence) {
      alerts.push({
        severity: "critical",
        title: "Sortie de zone",
        description: `${vehicleLabel} a quitté sa zone autorisée.`,
        dedupe: `geofence:${trackerId}:${hour}`,
      });
    }
  }
  return { alerts, insideGeofence };
}
