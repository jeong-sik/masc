// L3 probe 4: the override position under a granted origin. The position is
// read only when permissions.query already says granted.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => { try { const v = await fn(); log(step, v ?? null); return v; } catch (e) { log(step, { error: String((e && e.message) || e) }); } };
const origin = "http://127.0.0.1:18770";
const geo = (page) => page.evaluate(`navigator.permissions.query({ name: "geolocation" }).then(s => s.state)`);
const task = await taskSpace("masc-l3-environment-v2");
const page = task.page("p1");
await run("notifications 18769 in a new process", () => page.evaluate(`navigator.permissions.query({ name: "notifications" }).then(s => s.state)`));
await run("goto 18770", () => page.goto(origin + "/index.html"));
await run("setPermission", () => page.cdp("Browser.setPermission", { permission: { name: "geolocation" }, setting: "granted", origin }));
await run("override", () => page.cdp("Emulation.setGeolocationOverride", { latitude: 37.5665, longitude: 126.978, accuracy: 25 }));
const state = await run("state", () => geo(page));
if (state === "granted") {
  await run("position", () => page.evaluate(`new Promise(resolve => navigator.geolocation.getCurrentPosition(
    p => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude, accuracy: p.coords.accuracy }),
    e => resolve({ error: e.code + " " + e.message }), { timeout: 3000, maximumAge: 0 }))`));
} else {
  log("position", { skipped: "state is " + state });
}
await run("reset", () => page.cdp("Browser.resetPermissions", {}));
await run("clearOverride", () => page.cdp("Emulation.clearGeolocationOverride", {}));
await run("stateAfterReset", () => geo(page));
