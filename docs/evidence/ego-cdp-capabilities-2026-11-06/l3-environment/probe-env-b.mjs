// A new SDK process: is the geolocation grant still there?
const out = {};
const step = async (name, fn) => { try { out[name] = await fn(); } catch (error) { out[name] = {error: String(error && error.message || error)}; } };
const task = await taskSpace("masc-l3-environment");
out.spaceId = task.spaceId;
const page = task.page("p1");
await step("newProcess", () => page.evaluate(`(async () => ({
  url: location.href,
  geolocation: (await navigator.permissions.query({name: "geolocation"})).state,
  notifications: (await navigator.permissions.query({name: "notifications"})).state,
  intlLocale: Intl.DateTimeFormat().resolvedOptions().locale,
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone
}))()`));
await task.finish({keep: []});
console.log(JSON.stringify(out, null, 1));
