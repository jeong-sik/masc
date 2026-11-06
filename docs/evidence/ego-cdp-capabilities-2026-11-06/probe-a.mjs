const out = {};
const step = async (name, fn) => {
  try { out[name] = await fn(); } catch (error) { out[name] = { error: String(error && error.message || error) }; }
};
const task = await taskSpace("masc-capability-probe");
out.spaceId = task.spaceId;
const page = task.page("p1");
await page.goto("http://127.0.0.1:18767/index.html");
out.targetId = page.targetId;

await step("viewport.before", () => page.evaluate(() => ({ w: innerWidth, h: innerHeight })));
await step("viewport.set", () => page.cdp("Emulation.setDeviceMetricsOverride", { width: 800, height: 600, deviceScaleFactor: 0, mobile: false }));
await step("viewport.after", () => page.evaluate(() => ({ w: innerWidth, h: innerHeight })));

await step("touch.enable", () => page.cdp("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 }));
await step("touch.start", () => page.cdp("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: 100, y: 50 }] }));
await step("touch.end", () => page.cdp("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] }));
await page.waitForTimeout(300);
await step("touch.events", () => page.evaluate(() => window.__events));

await step("html.dom", async () => {
  const doc = await page.cdp("DOM.getDocument", { depth: 0 });
  const html = await page.cdp("DOM.getOuterHTML", { nodeId: doc.root.nodeId });
  return { bytes: html.outerHTML.length, head: html.outerHTML.slice(0, 60) };
});

await step("cookies.read", async () => {
  const answer = await page.cdp("Network.getCookies", { urls: ["http://127.0.0.1:18767/"] });
  return answer.cookies.map((cookie) => cookie.name);
});

await step("emulation.locale", () => page.cdp("Emulation.setLocaleOverride", { locale: "fr-FR" }));
await step("emulation.timezone", () => page.cdp("Emulation.setTimezoneOverride", { timezoneId: "America/New_York" }));
await step("emulation.geo", () => page.cdp("Emulation.setGeolocationOverride", { latitude: 37.5, longitude: 127.0, accuracy: 10 }));
await step("emulation.after", () => page.evaluate(() => ({ lang: navigator.language, intl: Intl.DateTimeFormat().resolvedOptions().locale, tz: Intl.DateTimeFormat().resolvedOptions().timeZone })));

await step("block.set", async () => {
  await page.cdp("Network.enable", {});
  return page.cdp("Network.setBlockedURLs", { urls: ["*blocked-probe*"] });
});
await step("block.fetch", () => page.evaluate(async () => {
  try { const response = await fetch("/blocked-probe.txt"); return { status: response.status }; }
  catch (error) { return { failed: String(error) }; }
}));
await step("network.events", async () => {
  await page.reload();
  const events = await page.events();
  return { count: events.length, methods: [...new Set(events.map((event) => event.method || event.type || Object.keys(event).join("|")))].slice(0, 12) };
});

await step("windows.forTarget", () => task.cdp("Browser.getWindowForTarget", { targetId: page.targetId }));

await step("zoom.scale", async () => {
  await page.cdp("Emulation.setPageScaleFactor", { pageScaleFactor: 2 });
  return page.evaluate(() => ({ visualScale: visualViewport.scale, dpr: devicePixelRatio, w: innerWidth }));
});

await step("console.default", async () => {
  await page.cdp("Runtime.enable", {});
  await page.evaluate(() => console.log("after enable"));
  const events = await page.events();
  return events.filter((event) => (event.method || "") === "Runtime.consoleAPICalled").length;
});

console.log(JSON.stringify(out, null, 1));
