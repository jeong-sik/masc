// What the invitation page shows when an invitation link is opened in a tab
// that already has the page. Run through `ego-browser nodejs` after replacing
// the __PLACEHOLDER__ values (the runtime passes no argv and no environment).
// Prints one JSON line per step.
//   __SPACE__  task space id or quoted name
//   __LABEL__  prefix of the PNG and JSON files
//   __OUT__    directory of the PNG and JSON files (absolute)
//   __BASE__   origin of an account server
// A step opens an address the way the address bar does (Page.navigate), and
// the row says whether the browser loaded a document for it. An address that
// differs from the open one in its fragment alone loads none.
const SPACE = __SPACE__;
const LABEL = "__LABEL__";
const OUT = "__OUT__";
const BASE = "__BASE__";
const SETTLE_MS = 3000;
const fs = await import("node:fs/promises");
await fs.mkdir(OUT, { recursive: true });

const task = await taskSpace(SPACE);
const page = task.page("p1");
await page.cdp("Page.enable");
await page.cdp("Emulation.clearDeviceMetricsOverride");

// Two made-up values of the shape of an invitation token (64 hex digits).
// No server issued them, and no step sends one.
const first = "a1".repeat(32);
const second = "b2".repeat(32);
const link = (token) => `${BASE}/accounts/invite#${token}`;

// The page as a person finds it. Runs in the page.
const readPage = (tokens) => {
  const visible = (e) => e !== null && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const field = document.getElementById("invite");
  const value = field === null ? null : field.value;
  const names = { [tokens.first]: "the first link", [tokens.second]: "the second link", "": "none" };
  const active = document.activeElement;
  return {
    path: location.pathname,
    // What the address bar shows after the path: 0, or "#" and a token (65).
    fragmentLength: location.hash.length,
    title: document.title,
    heading: [...document.querySelectorAll("h1")].filter(visible).map((e) => e.textContent.trim()).join(" / "),
    acceptShown: visible(document.getElementById("accept")),
    howToReopenShown: visible(document.getElementById("back")),
    // Whose token a press of the button would send.
    tokenInTheForm: value === null ? "no field" : (names[value] ?? "another value"),
    focus: active === null || active === document.body ? "body" : active.tagName.toLowerCase() + (active.id ? "#" + active.id : ""),
  };
};

// Waits until a document other than the marked one is loaded, and says so;
// or says that the marked one is still open when the wait is over.
async function settled() {
  const deadline = Date.now() + SETTLE_MS;
  for (;;) {
    let state = null;
    try {
      state = await page.evaluate(() => ({ ready: document.readyState === "complete", marked: window.__open_before_the_step === true }));
    } catch (_) {
      state = null;
    }
    if (state !== null && state.ready && !state.marked) return "a document was loaded";
    if (Date.now() >= deadline) return state !== null && state.marked ? "no document was loaded" : "not settled";
    await page.waitForTimeout(100);
  }
}

const rows = [];
async function step(sequence, name, act) {
  await page.evaluate(() => { window.__open_before_the_step = true; });
  await act();
  const load = await settled();
  const found = await page.evaluate(`(${readPage})(${JSON.stringify({ first, second })})`);
  await page.screenshot({ path: `${OUT}/${LABEL}-${sequence}-${name}.png`, fullPage: true });
  const row = { label: LABEL, sequence, step: name, load, ...found };
  rows.push(row);
  console.log(JSON.stringify(row));
  await fs.writeFile(`${OUT}/${LABEL}-invite-reopen.json`, JSON.stringify(rows, null, 2));
}
const open = (url) => page.cdp("Page.navigate", { url });

// A person opens the link, loads the tab again, and opens links in that tab.
await page.goto("about:blank");
await step("reopen", "1_open_the_first_link", () => open(link(first)));
await step("reopen", "2_load_the_tab_again", () => page.cdp("Page.reload"));
await step("reopen", "3_open_the_first_link_again", () => open(link(first)));
await step("reopen", "4_open_the_second_link", () => open(link(second)));

// A person has one invitation open and opens another in the same tab.
await page.goto("about:blank");
await step("replace", "1_open_the_first_link", () => open(link(first)));
await step("replace", "2_open_the_second_link", () => open(link(second)));
