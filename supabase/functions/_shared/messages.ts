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
};

export const errors = {
  invalidCode: "Code incorrect",
  locked: "Trop de tentatives. Réessayez dans quelques minutes.",
  homeNotFound: "Maison introuvable",
  noActiveSos: "Aucun SOS actif",
};
