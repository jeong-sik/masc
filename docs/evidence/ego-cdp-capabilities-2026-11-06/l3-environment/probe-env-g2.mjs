// L3 probe 5: clearing, a second override, bad values, and the next process.
// No prompt-capable call (getCurrentPosition is not called).
const log = (step, value) => console.log(JSON.stringify({ step, value }));
const run = async (step, fn) => { try { const v = await fn(); log(step, v ?? null); return v; } catch (e) { log(step, { error: String((e && e.message) || e) }); } };
const phase = "second";
const task = await taskSpace("masc-l3-environment-v3");
const page = task.page("p1");
const env = () => page.evaluate(`(async () => ({ intlLocale: Intl.DateTimeFormat().resolvedOptions().locale,
  numberLocale: new Intl.NumberFormat().resolvedOptions().locale, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  dateString: new Date(Date.UTC(2026, 0, 15, 12)).toString().slice(16), language: navigator.language,
  geolocation: (await navigator.permissions.query({ name: "geolocation" })).state }))()`);
if (phase === "first") {
  await run("goto", () => page.goto("http://127.0.0.1:18770/index.html"));
  await run("baseline", env);
  await run("setLocale fr-FR", () => page.cdp("Emulation.setLocaleOverride", { locale: "fr-FR" }));
  await run("setLocale de-DE while fr-FR", () => page.cdp("Emulation.setLocaleOverride", { locale: "de-DE" }));
  await run("setTimezone New_York", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "America/New_York" }));
  await run("setTimezone Paris while New_York", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "Europe/Paris" }));
  await run("afterSecond", env);
  await run("setTimezone bad", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "Mars/Olympus" }));
  await run("setLocale bad", () => page.cdp("Emulation.setLocaleOverride", { locale: "zz-ZZ-x-notreal" }));
  await run("afterBad", env);
  await run("clearLocale", () => page.cdp("Emulation.setLocaleOverride", {}));
  await run("clearTimezone", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "" }));
  await run("clearGeolocation", () => page.cdp("Emulation.clearGeolocationOverride", {}));
  await run("afterClear", env);
  await run("clearAgain", async () => [await page.cdp("Emulation.setLocaleOverride", {}), await page.cdp("Emulation.setTimezoneOverride", { timezoneId: "" })]);
  await run("set for next process", async () => [await page.cdp("Emulation.setLocaleOverride", { locale: "ja-JP" }), await page.cdp("Emulation.setTimezoneOverride", { timezoneId: "Asia/Tokyo" }),
    await page.cdp("Browser.setPermission", { permission: { name: "geolocation" }, setting: "granted", origin: "http://127.0.0.1:18770" })]);
  await run("beforeExit", env);
  await run("otherPage same origin", async () => { const p2 = task.page("p2"); await p2.goto("http://127.0.0.1:18770/index.html");
    return p2.evaluate(`(async () => ({ intlLocale: Intl.DateTimeFormat().resolvedOptions().locale, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, geolocation: (await navigator.permissions.query({ name: "geolocation" })).state }))()`); });
} else {
  await run("nextProcess", env);
}
