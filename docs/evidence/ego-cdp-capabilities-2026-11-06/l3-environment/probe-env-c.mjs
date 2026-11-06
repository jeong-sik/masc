// L3 probe 1: no call here can open a permission prompt.
// permissions.query only reads the state, CDP calls do not prompt, and
// getCurrentPosition is never called. Each step prints its own line at once.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const oldOrigin = "http://127.0.0.1:18768";
const freshOrigin = "http://127.0.0.1:18769";
const task = await taskSpace("masc-l3-environment-v2");
log("space", task.spaceId);
const page = task.page("p1");
const state = () => page.evaluate(`(async () => ({
  url: location.href,
  language: navigator.language,
  languages: navigator.languages,
  intlLocale: Intl.DateTimeFormat().resolvedOptions().locale,
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  offsetMinutes: new Date(Date.UTC(2026, 0, 15, 12)).getTimezoneOffset(),
  geolocation: (await navigator.permissions.query({ name: "geolocation" })).state
}))()`);
await run("gotoOld", () => page.goto(oldOrigin + "/index.html"));
await run("oldOrigin", state);
await run("gotoFresh", () => page.goto(freshOrigin + "/index.html"));
await run("before", state);
await run("setPermission", () => task.cdp("Browser.setPermission", {
  permission: { name: "geolocation" }, setting: "granted", origin: freshOrigin }));
await run("afterGrant", state);
await run("geolocationOverride", () => page.cdp("Emulation.setGeolocationOverride", { latitude: 37.5665, longitude: 126.978, accuracy: 25 }));
await run("localeOverride", () => page.cdp("Emulation.setLocaleOverride", { locale: "fr-FR" }));
await run("timezoneOverride", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "America/New_York" }));
await run("acceptLanguage", async () => page.cdp("Emulation.setUserAgentOverride", {
  userAgent: await page.evaluate("navigator.userAgent"), acceptLanguage: "fr-FR" }));
await run("afterOverrides", state);
await run("reload", () => page.reload());
await run("afterReload", state);
await run("reopen", async () => {
  const again = await taskSpace("masc-l3-environment-v2");
  return { spaceId: again.spaceId, sameProcessState: await again.page("p1").evaluate("navigator.language + ' ' + Intl.DateTimeFormat().resolvedOptions().timeZone") };
});
