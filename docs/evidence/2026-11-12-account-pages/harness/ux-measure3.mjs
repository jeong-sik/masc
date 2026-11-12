// Measures page states in a real browser. Run through `ego-browser nodejs`
// after replacing the __PLACEHOLDER__ values (the runtime passes no argv and
// no environment). Prints one JSON line per state.
//   __SPACE__   task space id or quoted name
//   __LABEL__   prefix of the PNG and JSON files
//   __OUT__     directory of the PNG and JSON files (absolute)
//   __AXE__     axe.min.js of axe-core (absolute)
//   __STATES__  JSON array of [name, base, scenario or null, path]
//               scenario is set on base/__scenario/<scenario> when not null
// Next to ux-measure2: the status and the policy come from a request of the
// script itself, the page counts the policy violations a browser reports, and
// the first Tab stop is recorded.
const SPACE = __SPACE__;
const LABEL = "__LABEL__";
const OUT = "__OUT__";
const STATES = __STATES__;
const AXE = "__AXE__";
const fs = await import("node:fs/promises");
const axeSource = await fs.readFile(AXE, "utf8");
await fs.mkdir(OUT, { recursive: true });

const task = await taskSpace(SPACE);
const page = task.page("p1");
// A browser reports each thing a policy refused as an event of the document.
// The listener is installed before any script of the page runs.
await page.cdp("Page.enable");
await page.cdp("Page.addScriptToEvaluateOnNewDocument", {
  source:
    "window.__violations = []; document.addEventListener('securitypolicyviolation', (e) => window.__violations.push(e.effectiveDirective + ' ' + (e.blockedURI || 'inline')));",
});
const results = [];
for (const [name, base, scenario, path] of STATES) {
  if (scenario !== null) await fetch(`${base}/__scenario/${scenario}`);
  const head = await fetch(`${base}${path.split("#")[0]}`, { redirect: "manual" });
  const policy = (head.headers.get("content-security-policy") || "").replace(/nonce-[0-9a-f]+/g, "nonce-N");
  await head.arrayBuffer();
  await page.cdp("Emulation.clearDeviceMetricsOverride");
  await page.goto("about:blank");
  await page.goto(`${base}${path}`);
  // A page with a status line is ready when the line has left "reading".
  await page.waitForFunction(
    () => {
      if (document.readyState !== "complete") return false;
      const out = document.getElementById("out");
      return out === null || out.textContent !== "reading";
    },
    undefined,
    { timeout: 10000 },
  );
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${OUT}/${LABEL}-${name}-desktop.png`, fullPage: true });

  await page.evaluate(axeSource);
  const axe = await page.evaluate(async () => {
    const run = await window.axe.run(document, {
      runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"] },
    });
    return {
      violations: run.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, first: v.nodes[0].target.join(" ") })),
      incomplete: run.incomplete.map((v) => `${v.id}(${v.nodes.length})`),
    };
  });

  const structure = await page.evaluate(() => {
    const visible = (e) => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
    const controls = [...document.querySelectorAll("button, input:not([type=hidden]), select, textarea, a[href]")].filter(visible);
    const freeText = controls.filter((e) => (e.tagName === "INPUT" && (e.type === "text" || e.type === "")) || e.tagName === "TEXTAREA");
    const small = controls.filter((e) => { const r = e.getBoundingClientRect(); return r.width < 24 || r.height < 24; });
    const raw = [...document.querySelectorAll("pre")].filter(visible).map((e) => e.textContent).filter((t) => /\(\d{3}\)|\{"/.test(t));
    const heights = controls.map((e) => Math.round(e.getBoundingClientRect().height));
    return {
      landmarks: document.querySelectorAll("main, nav, header, footer, [role=main]").length,
      liveRegions: document.querySelectorAll("[role=status], [role=alert], [role=log], [aria-live]").length,
      visibleControls: controls.length,
      freeTextFields: freeText.length,
      targetsUnder24px: small.length,
      smallestControlHeight: heights.length === 0 ? null : Math.min(...heights),
      rawServerTextBlocks: raw.length,
      styleRules: [...document.styleSheets].reduce((n, s) => n + s.cssRules.length, 0),
      styleAttributes: document.querySelectorAll("[style]").length,
      bodyBackground: getComputedStyle(document.body).backgroundColor,
      policyViolations: window.__violations === undefined ? "not counted" : window.__violations,
      lang: document.documentElement.lang,
      title: document.title,
    };
  });

  // The first Tab from the top of the page: where the focus lands, and
  // whether a browser draws a ring there.
  let firstTabStop = "not measured";
  try {
    await page.evaluate(() => { if (document.activeElement) document.activeElement.blur(); window.scrollTo(0, 0); });
    await page.keyboard.press("Tab");
    firstTabStop = await page.evaluate(() => {
      const e = document.activeElement;
      if (e === null || e === document.body) return "body";
      const style = getComputedStyle(e);
      return `${e.tagName.toLowerCase()}${e.id ? "#" + e.id : ""} outline=${style.outlineStyle} ${style.outlineWidth}`;
    });
  } catch (error) {
    firstTabStop = `not measured: ${String(error).slice(0, 80)}`;
  }

  await page.cdp("Emulation.setDeviceMetricsOverride", { width: 320, height: 800, deviceScaleFactor: 2, mobile: true });
  await page.waitForTimeout(200);
  const reflow = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }));
  await page.screenshot({ path: `${OUT}/${LABEL}-${name}-320.png`, fullPage: true });
  await page.cdp("Emulation.clearDeviceMetricsOverride");

  const row = {
    label: LABEL,
    state: name,
    httpStatus: head.status,
    policy,
    axeViolations: axe.violations.reduce((n, v) => n + v.nodes, 0),
    axeRules: axe.violations.map((v) => `${v.id}(${v.impact},${v.nodes}) at ${v.first}`),
    axeIncomplete: axe.incomplete,
    ...structure,
    firstTabStop,
    horizontalScrollAt320: reflow.scrollWidth > reflow.clientWidth ? `${reflow.scrollWidth}px wide in ${reflow.clientWidth}px` : "none",
  };
  results.push(row);
  console.log(JSON.stringify(row));
}
await fs.writeFile(`${OUT}/${LABEL}-measure.json`, JSON.stringify(results, null, 2));
