// Environment overrides and the geolocation grant on ego, in one SDK process.
const out = {};
const step = async (name, fn) => { try { out[name] = await fn(); } catch (error) { out[name] = {error: String(error && error.message || error)}; } };
const origin = "http://127.0.0.1:18768";
const task = await taskSpace("masc-l3-environment");
out.spaceId = task.spaceId;
const page = task.page("p1");
await page.goto(origin + "/index.html");
const env = () => page.evaluate(`(async () => ({
  language: navigator.language,
  intlLocale: Intl.DateTimeFormat().resolvedOptions().locale,
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  geolocation: (await navigator.permissions.query({name: "geolocation"})).state,
  notifications: (await navigator.permissions.query({name: "notifications"})).state,
  camera: (await navigator.permissions.query({name: "camera"})).state
}))()`);
const position = () => page.evaluate(`new Promise(resolve => navigator.geolocation.getCurrentPosition(
  p => resolve({latitude: p.coords.latitude, longitude: p.coords.longitude, accuracy: p.coords.accuracy}),
  e => resolve({error: e.code + " " + e.message}), {timeout: 3000, maximumAge: 0}))`);
await step("before", env);
await step("setPermission", () => task.cdp("Browser.setPermission", {permission: {name: "geolocation"}, setting: "granted", origin}));
await step("afterGrant", env);
await step("geolocationOverride", () => page.cdp("Emulation.setGeolocationOverride", {latitude: 37.5665, longitude: 126.978, accuracy: 25}));
await step("position", position);
await step("localeOverride", () => page.cdp("Emulation.setLocaleOverride", {locale: "fr-FR"}));
await step("timezoneOverride", () => page.cdp("Emulation.setTimezoneOverride", {timezoneId: "America/New_York"}));
await step("afterOverrides", env);
await page.reload();
await step("afterReload", env);
await step("positionAfterReload", position);
await step("clearGeolocation", () => page.cdp("Emulation.clearGeolocationOverride", {}));
await step("clearLocale", () => page.cdp("Emulation.setLocaleOverride", {}));
await step("clearTimezone", () => page.cdp("Emulation.setTimezoneOverride", {timezoneId: ""}));
await step("afterClear", env);
await step("positionAfterClear", position);
console.log(JSON.stringify(out, null, 1));
