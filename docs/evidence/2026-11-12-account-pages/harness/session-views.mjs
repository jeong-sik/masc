// Which view the home page shows for what the session routes answer, and
// what it shows after a press of the sign-out button. Run through
// `ego-browser nodejs` after replacing the __PLACEHOLDER__ values (the runtime
// passes no argv and no environment). Prints one JSON line per case.
//   __SPACE__  task space id or quoted name
//   __LABEL__  prefix of the PNG and JSON files
//   __OUT__    directory of the PNG and JSON files (absolute)
//   __BASE__   origin of the JSON stand-in (ux-mock.mjs) that serves the home
//              page a real server answered
// A case is a scenario of the stand-in and whether the sign-out button is
// pressed. The button is pressed with the keyboard. The row also holds what
// the session route answers afterwards, which is what is true of the session.
const SPACE = __SPACE__;
const LABEL = "__LABEL__";
const OUT = "__OUT__";
const BASE = "__BASE__";
const READY_TIMEOUT_MS = 60000;
const SETTLE_MS = 5000;
const IDLE_MS = 400;
const CASES = [
  ["session_unread", "session_unread", false],
  ["signout_ended", "member_full", true],
  ["signout_refused", "signout_refused", true],
  ["signout_refused_then_unread", "zone_stops_at_signout", true],
];
const fs = await import("node:fs/promises");
await fs.mkdir(OUT, { recursive: true });

const task = await taskSpace(SPACE);
const page = task.page("p1");
await page.cdp("Page.enable");
await page.cdp("Emulation.clearDeviceMetricsOverride");

// A page with a status line is ready when the line has left "reading".
const ready = () =>
  page.waitForFunction(
    () => document.readyState === "complete" && document.getElementById("out").textContent !== "reading",
    undefined,
    { timeout: READY_TIMEOUT_MS },
  );

// The page as a person finds it. Runs in the page.
const readPage = () => {
  const visible = (e) => e !== null && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const views = { signin: "the sign-in", "signed-in": "the tools of a signed-in person", unread: "that the session was not read" };
  const out = document.getElementById("out");
  const active = document.activeElement;
  return {
    viewsShown: Object.keys(views).filter((id) => visible(document.getElementById(id))).map((id) => views[id]),
    heading: [...document.querySelectorAll("h1")].filter(visible).map((e) => e.textContent.trim()).join(" / "),
    // The first line of the status line, when a person can see it.
    statusLine: visible(out) ? out.textContent.split("\n")[0] : null,
    alertsShown: [...document.querySelectorAll("[role=alert]")].filter(visible).length,
    focus: active === null || active === document.body ? "body" : active.tagName.toLowerCase() + (active.id ? "#" + active.id : ""),
    // The made-up ids of the person (accounts, Runtimes, tokens) that the
    // document still holds, shown or hidden.
    idsOfThePersonInTheDocument: (document.body.textContent.match(/\b(?:pa|rt|pat|usr)_[0-9A-Z]{6,}/g) || []).length,
  };
};

// Marks the open document and counts its requests, so that the end of what
// a press starts can be told without a fixed wait. Runs in the page.
const watch = () => {
  window.__open_before_the_press = true;
  window.__requests = 0;
  window.__pending = 0;
  window.__idleSince = performance.now();
  const send = window.fetch;
  window.fetch = (...args) => {
    window.__requests += 1;
    window.__pending += 1;
    const done = () => { window.__pending -= 1; window.__idleSince = performance.now(); };
    return send(...args).then((answer) => { done(); return answer; }, (error) => { done(); throw error; });
  };
};

// Waits for a document other than the marked one, or for the marked one to
// have sent something and then nothing for IDLE_MS.
async function settled() {
  const deadline = Date.now() + SETTLE_MS;
  for (;;) {
    let state = null;
    try {
      state = await page.evaluate(() => ({
        ready: document.readyState === "complete",
        marked: window.__open_before_the_press === true,
        requests: window.__requests || 0,
        idleFor: window.__pending === 0 ? performance.now() - window.__idleSince : 0,
      }));
    } catch (_) {
      state = null;
    }
    if (state !== null && state.ready && !state.marked) return { load: "a document was loaded", requests: null };
    if (state !== null && state.marked && state.requests > 0 && state.idleFor >= IDLE_MS) return { load: "no document was loaded", requests: state.requests };
    if (Date.now() >= deadline) return { load: "not settled", requests: state === null ? null : state.requests };
    await page.waitForTimeout(100);
  }
}

const rows = [];
for (const [name, scenario, press] of CASES) {
  await fetch(`${BASE}/__scenario/${scenario}`);
  await page.goto("about:blank");
  await page.goto(`${BASE}/`);
  await ready();
  let row = { label: LABEL, case: name, scenario, pressed: press };
  if (press) {
    // The lists of a signed-in person are read one after another; the tokens
    // are last.
    await page.waitForFunction(() => document.getElementById("pats").textContent !== "reading", undefined, { timeout: READY_TIMEOUT_MS });
    const before = await page.evaluate(readPage);
    await page.evaluate(watch);
    await page.evaluate(() => document.getElementById("signout").focus());
    await page.keyboard.press("Enter");
    const end = await settled();
    if (end.load === "a document was loaded") await ready();
    row = { ...row, beforeThePress: { viewsShown: before.viewsShown, idsOfThePersonInTheDocument: before.idsOfThePersonInTheDocument }, load: end.load, requestsOfThePress: end.requests };
  }
  const found = await page.evaluate(readPage);
  const session = await fetch(`${BASE}/auth/session`);
  await session.arrayBuffer();
  row = { ...row, ...found, sessionRouteAfterwards: session.status };
  await page.screenshot({ path: `${OUT}/${LABEL}-${name}.png`, fullPage: true });
  rows.push(row);
  console.log(JSON.stringify(row));
  await fs.writeFile(`${OUT}/${LABEL}-session-views.json`, JSON.stringify(rows, null, 2));
}
