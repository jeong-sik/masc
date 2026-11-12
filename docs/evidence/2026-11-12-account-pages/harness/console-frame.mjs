// Measures the frame of the console in a real browser, over console-mock.mjs:
// where the line that names the place and the column under it start and end,
// how tall the line is while the page reads and once the session is read,
// and what the page does when a sign-out or a reading fails. Run through
// `ego-browser nodejs` after console-frame-run.py has filled the
// placeholders. Prints one JSON line per measurement and writes them all to
// OUT/LABEL-frame.json.
//   __SPACE__  task space id or quoted name
//   __LABEL__  prefix of the files
//   __OUT__    directory of the files (absolute)
//   __MOCK__   address of console-mock.mjs, which serves a saved console
const SPACE = __SPACE__;
const LABEL = "__LABEL__";
const OUT = "__OUT__";
const MOCK = "__MOCK__";
const READY_TIMEOUT_MS = 30000;
// What the page is given to answer a press before it is read: the mock
// answers at once, so this is the time of the page and the browser alone.
const SETTLE_MS = 500;
const WIDTHS = [1548, 1280, 320];
// The size of the letters of a browser as it comes, and two larger ones.
const DEFAULT_LETTERS_PX = 16;
const LARGER_LETTERS_PX = [20, 24];
const fs = await import("node:fs/promises");

const task = await taskSpace(SPACE);
const page = task.page("p1");
const results = [];

const call = (path) => fetch(`${MOCK}${path}`).then((r) => r.json());

async function until(fn, arg, what) {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  for (;;) {
    let met = false;
    try {
      met = await page.evaluate(fn, arg);
    } catch (_) {
      met = false; // the document is being replaced
    }
    if (met) return;
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
    await page.waitForTimeout(50);
  }
}

// The console has drawn the state of `kind`: signed_in has the sign-out
// button, failed the retry button, reading no button at all.
const drawn = (kind) => {
  if (document.readyState !== "complete" || location.pathname !== "/accounts/console") return false;
  const app = document.getElementById("app");
  if (app === null || app.childElementCount === 0) return false;
  if (kind === "signed_in") return document.querySelector("header button") !== null;
  if (kind === "failed") return document.querySelector("main button") !== null;
  if (kind === "reading") return document.querySelector("button") === null;
  return false;
};

// Where things stand, in CSS px of the window.
const geometry = () => {
  const rect = (e) => (e === null ? null : e.getBoundingClientRect());
  const round = (n) => (n === null ? null : Math.round(n * 10) / 10);
  const header = document.querySelector(".site-header");
  const main = document.querySelector("main");
  const h = rect(header);
  const m = rect(main);
  const mainStyle = getComputedStyle(main);
  const brand = rect(document.querySelector(".brand"));
  const heading = rect(document.querySelector("main h1"));
  const account = rect(document.querySelector(".account"));
  const signOut = document.querySelector("header button");
  const back = document.querySelector('main a[href="/"]');
  const visible = (e) => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const controls = [...document.querySelectorAll("button, a[href]")].filter(visible);
  const columnRight = m.right - parseFloat(mainStyle.paddingRight);
  return {
    width: window.innerWidth,
    headerHeight: round(h.height),
    brandLeft: round(brand.left),
    headingLeft: round(heading.left),
    accountRight: account === null ? null : round(account.right),
    columnRight: round(columnRight),
    signOutMarginTop: signOut === null ? null : getComputedStyle(signOut).marginTop,
    signOutTop: signOut === null ? null : round(rect(signOut).top - h.top),
    headingTop: round(heading.top),
    backLinkHeight: back === null ? null : round(rect(back).height),
    smallestControlHeight: controls.length === 0 ? null : round(Math.min(...controls.map((e) => rect(e).height))),
    horizontalScroll: document.documentElement.scrollWidth > document.documentElement.clientWidth,
  };
};

// The note of a failure and the line under the retry button, and where the
// focus is. `mark` tags the note on the page, so a later reading can say
// whether the note is the same element or a new one.
const notes = (mark) => {
  const alerts = [...document.querySelectorAll("[role=alert]")];
  const status = [...document.querySelectorAll("main [role=status]")].map((e) => e.textContent);
  const focused = document.activeElement;
  const result = {
    alerts: alerts.length,
    alertIsNew: alerts.length === 1 ? alerts[0].dataset.measured === undefined : null,
    alertText: alerts.map((e) => e.innerText.replace(/\s+/g, " ").trim()),
    statusLines: status,
    focus: focused === null || focused === document.body ? "body" : `${focused.tagName.toLowerCase()} ${focused.textContent.trim()}`,
    shownId: (document.querySelector(".account .hint") || { textContent: null }).textContent,
    signOutShown: document.querySelector("header button") !== null,
    path: location.pathname,
  };
  if (mark) for (const e of alerts) e.dataset.measured = "1";
  return result;
};

async function open(scenario, width) {
  await call(`/__scenario/${scenario}`);
  await page.cdp("Emulation.setDeviceMetricsOverride", { width, height: 990, deviceScaleFactor: 1, mobile: width < 600 });
  await page.goto("about:blank");
  await page.goto(`${MOCK}/accounts/console`);
}

/** Presses the button named by `selector` from the keyboard, as a person who
    moved the focus there does. */
async function press(selector) {
  await page.evaluate((s) => { document.querySelector(s).focus(); }, selector);
  await page.keyboard.press("Enter");
  await page.waitForTimeout(SETTLE_MS);
}

function record(row) {
  const full = { label: LABEL, ...row };
  results.push(full);
  console.log(JSON.stringify(full));
}

// 1. The line and the column, signed in, at each width; and the line while
//    the page reads, held until the reading is measured. Then the same at
//    1280px with the larger letters a person can set in the browser.
async function line(width) {
  await call("/__hold");
  await open("member", width);
  await until(drawn, "reading", "the reading state");
  const reading = await page.evaluate(geometry);
  await call("/__release");
  await until(drawn, "signed_in", "the signed-in state");
  await page.waitForTimeout(200);
  return { reading, signedIn: await page.evaluate(geometry) };
}
for (const width of WIDTHS) record({ measure: "geometry", width, ...(await line(width)) });
for (const fontSize of LARGER_LETTERS_PX) {
  await page.cdp("Page.setFontSizes", { fontSizes: { standard: fontSize } });
  record({ measure: "geometry_letters", width: 1280, fontSize, ...(await line(1280)) });
}
await page.cdp("Page.setFontSizes", { fontSizes: { standard: DEFAULT_LETTERS_PX } });
await page.cdp("Emulation.setDeviceMetricsOverride", { width: 1280, height: 990, deviceScaleFactor: 1, mobile: false });

// 2. The focus once the first reading ends.
await open("member", 1280);
await until(drawn, "signed_in", "the signed-in state");
await page.waitForTimeout(200);
record({ measure: "first_reading", ...(await page.evaluate(notes, false)) });

// 3. A sign-out the server refuses, pressed twice.
await open("signout_refused", 1280);
await until(drawn, "signed_in", "the signed-in state");
await press("header button");
const firstRefusal = await page.evaluate(notes, true);
await press("header button");
const secondRefusal = await page.evaluate(notes, false);
await page.screenshot({ path: `${OUT}/${LABEL}-sign_out_refused_twice.png` });
record({ measure: "sign_out_refused_twice", first: firstRefusal, second: secondRefusal, seen: await call("/__seen") });

// 4. A sign-out after another tab signed in again as the same person, and
//    after another person signed in.
for (const [name, rotate] of [["signed_in_again", "/__rotate"], ["another_person", "/__rotate?user=usr_01JCMOTHER0000"]]) {
  await open("member", 1280);
  await until(drawn, "signed_in", "the signed-in state");
  await call(rotate);
  await press("header button");
  const after = await page.evaluate(notes, true);
  const pressedAgain = after.path === "/accounts/console" && after.alerts > 0 && after.signOutShown;
  let again = null;
  if (pressedAgain) {
    await press("header button");
    again = await page.evaluate(notes, false);
  }
  record({ measure: `sign_out_${name}`, after, again, seen: await call("/__seen") });
}

// 5. A reading that fails, and a retry that fails again.
await open("session_unread", 1280);
await until(drawn, "failed", "the failed state");
const firstFailure = await page.evaluate(notes, true);
await press("main button");
const secondFailure = await page.evaluate(notes, false);
await page.screenshot({ path: `${OUT}/${LABEL}-retry_failed_again.png` });
record({ measure: "retry_failed_again", first: firstFailure, second: secondFailure, seen: await call("/__seen") });

await page.cdp("Emulation.clearDeviceMetricsOverride");
await fs.writeFile(`${OUT}/${LABEL}-frame.json`, JSON.stringify(results, null, 2));
