// L3 probe 2: which permission commands does ego pass through? No prompt-capable call.
const log = (step, value) => console.log(JSON.stringify({ step, value }));
const run = async (step, fn) => { try { log(step, (await fn()) ?? null); } catch (e) { log(step, { error: String((e && e.message) || e) }); } };
const origin = "http://127.0.0.1:18769";
const task = await taskSpace("masc-l3-environment-v2");
const page = task.page("p1");
await run("task Browser.grantPermissions", () => task.cdp("Browser.grantPermissions", { permissions: ["geolocation"], origin }));
await run("page Browser.setPermission", () => page.cdp("Browser.setPermission", { permission: { name: "geolocation" }, setting: "granted", origin }));
await run("page Browser.grantPermissions", () => page.cdp("Browser.grantPermissions", { permissions: ["geolocation"], origin }));
await run("task Browser.getVersion", () => task.cdp("Browser.getVersion", {}));
await run("task Browser.resetPermissions", () => task.cdp("Browser.resetPermissions", {}));
await run("state", () => page.evaluate(`navigator.permissions.query({ name: "geolocation" }).then(s => s.state)`));
