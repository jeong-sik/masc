// L3 probe 6: what the page reports for each requested locale and time zone.
const task = await taskSpace("masc-l3-environment-v3");
const page = task.page("p1");
const read = () => page.evaluate(`({ locale: Intl.DateTimeFormat().resolvedOptions().locale, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, offset: new Date(Date.UTC(2026,0,15,12)).getTimezoneOffset() })`);
for (const zone of ["Asia/Calcutta", "Asia/Kolkata", "US/Eastern", "asia/seoul", "UTC", "Etc/GMT+5", "Mars/Olympus", "Europe/Paris", "Mars/Olympus", ""]) {
  let error = null; try { await page.cdp("Emulation.setTimezoneOverride", { timezoneId: zone }); } catch (e) { error = String(e.message || e); }
  console.log(JSON.stringify({ zone, error, seen: await read() }));
}
for (const locale of ["fr-fr", "en", "zh-Hant-TW", "sr-Latn", "x-bad", "123", "", "de-DE"]) {
  let error = null; try { await page.cdp("Emulation.setLocaleOverride", locale === "" ? {} : { locale }); } catch (e) { error = String(e.message || e); }
  console.log(JSON.stringify({ locale, error, seen: await read() }));
}
await page.cdp("Emulation.setLocaleOverride", {}); await page.cdp("Emulation.setTimezoneOverride", { timezoneId: "" });
console.log(JSON.stringify({ cleared: await read() }));
