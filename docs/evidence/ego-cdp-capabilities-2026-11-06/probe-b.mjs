const out = {};
const step = async (name, fn) => {
  try { out[name] = await fn(); } catch (error) { out[name] = { error: String(error && error.message || error) }; }
};
const task = await taskSpace("masc-capability-probe");
const page = task.page("p1");
await step("persist.viewport", () => page.evaluate(() => ({ w: innerWidth, h: innerHeight })));
await step("persist.emulation", () => page.evaluate(() => ({ intl: Intl.DateTimeFormat().resolvedOptions().locale, tz: Intl.DateTimeFormat().resolvedOptions().timeZone })));
await step("persist.block", () => page.evaluate(async () => {
  try { const response = await fetch("/blocked-probe.txt"); return { status: response.status }; }
  catch (error) { return { failed: String(error) }; }
}));
await step("persist.scale", () => page.evaluate(() => visualViewport.scale));
await step("console.disable", () => page.cdp("egoAutomated.disable", {}));
await step("console.enable", () => page.cdp("Runtime.enable", {}));
await page.evaluate(() => console.log("after disable"));
await page.waitForTimeout(200);
await step("console.events", async () => {
  const events = await page.events();
  return events.filter((event) => (event.method || "") === "Runtime.consoleAPICalled").map((event) => event.params && event.params.args && event.params.args.map((arg) => arg.value));
});
await step("console.reenable", () => page.cdp("egoAutomated.enable", {}));
console.log(JSON.stringify(out, null, 1));
