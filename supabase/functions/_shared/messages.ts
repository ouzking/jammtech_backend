// Textes destinés aux utilisateurs (français ; wolof et anglais à venir).
// SMS : uniquement des caractères de l'alphabet GSM-7 (é, è, à, ù sont
// acceptés ; pas de ê, ô, î, ç, ni de guillemets typographiques) pour éviter
// le passage en UCS-2, qui divise par deux la longueur d'un segment.

export type Lang = "fr" | "wo" | "en";

export const sms = {
  otp: (code: string) => `JammTech : votre code est ${code}. Ne le partagez avec personne.`,
  sosAlert: (name: string, phone: string | null, url: string | null) =>
    `SOS JammTech : ${name} a besoin d'aide.` +
    (url ? ` Position : ${url}` : "") +
    (phone ? ` Appelez : ${phone}` : ""),
  sosSilent: (name: string, url: string | null) =>
    `ALERTE DISCRETE JammTech : ${name} est peut-etre sous la contrainte. NE l'appelez PAS.` +
    (url ? ` Position : ${url}` : "") + " Contactez le 17 si besoin.",
  sosResolved: (name: string) => `JammTech : ${name} est en sécurité. L'alerte SOS est terminée.`,
  sosCancelled: (name: string) => `JammTech : fausse alerte de ${name}. Tout va bien.`,
  alert: (title: string, location: string | null) =>
    `JammTech : ${title}${location ? ` (${location})` : ""}. Ouvrez l'application pour plus de détails.`,
  tripStarted: (name: string, mode: string, plate: string | null, eta: string, url: string | null) =>
    `JammTech : ${name} a commencé un trajet (${mode}${plate ? `, ${plate}` : ""}), arrivée prévue à ${eta}.` +
    (url ? ` Suivre : ${url}` : ""),
  tripArrived: (name: string, time: string) => `JammTech : ${name} est bien arrivé(e) à ${time}.`,
  tripCancelled: (name: string) => `JammTech : ${name} a annulé son trajet. Tout va bien.`,
  tripBatteryLow: (name: string, level: number, url: string | null) =>
    `JammTech : batterie de ${name} à ${level} %, son téléphone risque de s'éteindre.` +
    (url ? ` Dernière position : ${url}` : ""),
  tripCheckin: (minutes: number) =>
    `JammTech : tout va bien ? Ouvrez l'application pour confirmer, sinon vos proches seront alertés dans ${minutes} min.`,
};

export const push = {
  sosAlert: (name: string) => ({
    title: `🚨 SOS de ${name}`,
    body: `${name} a besoin d'aide. Touchez pour voir sa position en direct.`,
  }),
  sosSilent: (name: string) => ({
    title: `⚠️ Alerte discrète de ${name}`,
    body: `${name} est peut-être sous la contrainte. Ne l'appelez pas. Suivez sa position.`,
  }),
  sosResolved: (name: string) => ({ title: `${name} est en sécurité`, body: "L'alerte SOS est terminée." }),
  sosCancelled: (name: string) => ({ title: `Fausse alerte de ${name}`, body: "Tout va bien." }),
  tripStarted: (name: string, mode: string, eta: string) => ({
    title: `Trajet de ${name}`,
    body: `${mode} · arrivée prévue à ${eta}. Touchez pour suivre.`,
  }),
  tripCheckin: (minutes: number) => ({
    title: "Tout va bien ?",
    body: `Confirmez avec votre code, sinon vos proches seront alertés dans ${minutes} min.`,
  }),
  tripLate: (name: string, minutes: number) => ({
    title: `${name} n'est pas encore arrivé·e`,
    body: `Retard de ${minutes} min sur l'heure prévue.`,
  }),
  tripArrived: (name: string, time: string) => ({ title: `${name} est arrivé·e`, body: `Arrivé·e à ${time}.` }),
  tripCancelled: (name: string) => ({ title: `Trajet de ${name} annulé`, body: "Tout va bien." }),
  tripBatteryLow: (name: string, level: number) => ({
    title: `Batterie faible : ${name}`,
    body: `${level} % — touchez pour voir la dernière position.`,
  }),
};

export const tripModes: Record<string, string> = {
  taxi: "taxi",
  clando: "clando",
  moto: "moto",
  public: "transport en commun",
  walk: "à pied",
  car: "voiture",
};

/** Heure locale de Dakar au format « 20 h 14 ». */
export function dakarTime(iso: string | Date): string {
  const parts = new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Africa/Dakar",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date(iso));
  const h = parts.find((p) => p.type === "hour")?.value ?? "00";
  const m = parts.find((p) => p.type === "minute")?.value ?? "00";
  return `${Number(h)} h ${m}`;
}

export const errors = {
  invalidCode: "Code incorrect",
  locked: "Trop de tentatives. Réessayez dans quelques minutes.",
  homeNotFound: "Maison introuvable",
  noActiveSos: "Aucun SOS actif",
  noActiveTrip: "Aucun trajet en cours",
  tripAlreadyActive: "Un trajet est déjà en cours",
};
