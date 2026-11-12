// What a press of the button of the invitation page sends when a person opens
// a second invitation link in the tab that shows the first one and presses
// before the server answered. Run through `ego-browser nodejs` after
// replacing the __PLACEHOLDER__ values (the runtime passes no argv and no
// environment). Prints one JSON line per case.
//   __SPACE__  task space id or quoted name
//   __LABEL__  prefix of the PNG and JSON files
//   __OUT__    directory of the PNG and JSON files (absolute)
//   __BASE__   origin of the stand-in of invite-delay.mjs in front of an
//              account server
//   __BINARY__ first 12 hex digits of the sha256 of the binary of that server
// In each case the stand-in holds the answer of the next invitation page for
// holdMs. The second link is opened from the page (location.href), which
// changes the fragment alone, as the address bar does. With Page.navigate
// the press came only after the hold and hit the page that was loaded again.
// pressAtMs after the link is opened the case acts, with no question to the
// page before it:
//   mouse    the mouse presses where the button of the first link was;
//   Enter,   the key goes to the button of the first link, which took the
//   Space    focus before the second link was opened;
//   capture  nothing is pressed and the screen is captured. The capture is
//            kept only when it came within the hold.
// The page is not asked what it shows while it waits. A record the page wrote
// into window.name while its reload waited did not reach the page that was
// loaded next, and one written in one run was read in the next run. A row
// says when the act came, and which binary answered.
const SPACE = __SPACE__;
const LABEL = "__LABEL__";
const OUT = "__OUT__";
const BASE = "__BASE__";
const BINARY = "__BINARY__";
const CASES = [
  { holdMs: 300, pressAtMs: 150, act: "mouse" },
  { holdMs: 2000, pressAtMs: 400, act: "mouse" },
  { holdMs: 2000, pressAtMs: 400, act: "Enter" },
  { holdMs: 2000, pressAtMs: 400, act: "Space" },
  { holdMs: 2000, pressAtMs: 400, act: "capture" },
];
// The events of a key as a keyboard sends them; the text makes the key press.
const KEYS = {
  Enter: { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: "\r" },
  Space: { key: " ", code: "Space", windowsVirtualKeyCode: 32, nativeVirtualKeyCode: 32, text: " " },
};
// Longer than the longest hold.
const SETTLE_MS = 5000;
const fs = await import("node:fs/promises");
await fs.mkdir(OUT, { recursive: true });
// A run that stops early leaves no file of a run before it.
const ROWS_FILE = `${OUT}/${LABEL}-invite-press.json`;
const CAPTURE_FILE = `${OUT}/${LABEL}-while_the_server_answers.png`;
await fs.rm(ROWS_FILE, { force: true });
await fs.rm(CAPTURE_FILE, { force: true });

const task = await taskSpace(SPACE);
const page = task.page("p1");
await page.cdp("Page.enable");
await page.cdp("Emulation.clearDeviceMetricsOverride");

// Two made-up values of the shape of an invitation token (64 hex digits).
// No server issued them, and the stand-in takes every start.
const first = "a1".repeat(32);
const second = "b2".repeat(32);
const link = (token) => `${BASE}/accounts/invite#${token}`;
const names = { [first]: "the first link", [second]: "the second link", "": "an empty value" };
const named = (value) => (value === null ? "no field" : (names[value] ?? "another value"));
const standIn = async (path) => (await fetch(`${BASE}${path}`)).json();

// The page as a person finds it, and the middle of its button. Runs in the page.
const readPage = () => {
  const visible = (e) => e !== null && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const button = document.getElementById("go");
  const field = document.getElementById("invite");
  const box = visible(button) ? button.getBoundingClientRect() : null;
  return {
    page: document.title === "start" ? "the page of the stand-in after a start" : location.pathname,
    fragmentLength: location.hash.length,
    buttonShown: visible(button),
    invite: field === null ? null : field.value,
    middle: box === null ? null : { x: box.left + box.width / 2, y: box.top + box.height / 2 },
  };
};
const look = async () => {
  const found = await page.evaluate(readPage);
  return { ...found, invite: named(found.invite) };
};

// Waits until a document other than the marked one is loaded, and says so;
// or says that the marked one is still open when the wait is over.
const mark = () => page.evaluate(() => { window.__open_before_the_step = true; });
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
const open = (url) => page.cdp("Page.navigate", { url });
const openFromThePage = (url) => page.cdp("Runtime.evaluate", { expression: `location.href = ${JSON.stringify(url)}` });
const click = async ({ x, y }) => {
  await page.cdp("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
  await page.cdp("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
  await page.cdp("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
};
const type = async (name) => {
  const { text, ...key } = KEYS[name];
  await page.cdp("Input.dispatchKeyEvent", { type: "keyDown", ...key, text, unmodifiedText: text });
  await page.cdp("Input.dispatchKeyEvent", { type: "keyUp", ...key });
};
// Gives the button the focus, as a person who tabs to it; runs in a loaded page.
const focusButton = async () => {
  const focused = await page.evaluate(() => {
    document.getElementById("go").focus();
    return document.activeElement === null ? null : document.activeElement.id;
  });
  if (focused !== "go") throw new Error(`the button did not take the focus: ${focused}`);
};
const press = (act, middle) => (act === "mouse" ? click(middle) : type(act));
const startsSince = (before, after) => after.starts.slice(before.starts.length).map(named);

const rows = [];
for (const { holdMs, pressAtMs, act } of CASES) {
  const pressing = act !== "capture";
  const byKey = act in KEYS;
  await page.goto("about:blank");
  await mark();
  await open(link(first));
  const firstLoad = await settled();
  const firstPage = await page.evaluate(readPage);
  if (firstPage.middle === null || named(firstPage.invite) !== "the first link") {
    throw new Error(`the first link did not open the form of the invitation page: ${firstLoad}, ${firstPage.page}`);
  }
  if (byKey) await focusButton();
  await standIn(`/__stand_in/hold?ms=${holdMs}`);
  const before = await standIn("/__stand_in");
  await mark();
  const openedAt = Date.now();
  await openFromThePage(link(second));
  const openReturnedAfterMs = Date.now() - openedAt;
  const left = pressAtMs - openReturnedAfterMs;
  if (left > 0) await page.waitForTimeout(left);
  if (pressing) await press(act, firstPage.middle);
  const shot = pressing ? null : await page.cdp("Page.captureScreenshot", { format: "png" });
  const actedAfterMs = Date.now() - openedAt;
  if (shot !== null && actedAfterMs < holdMs) await fs.writeFile(CAPTURE_FILE, Buffer.from(shot.data, "base64"));
  const load = await settled();
  const afterPress = await standIn("/__stand_in");
  // A page that did not load again leaves the hold for the next case.
  await standIn("/__stand_in/hold?ms=0");
  const then = await look();
  let laterPress = "no button";
  if (then.buttonShown && then.middle !== null) {
    const middle = then.middle;
    if (byKey) await focusButton();
    await mark();
    await press(pressing ? act : "mouse", middle);
    await settled();
    laterPress = startsSince(afterPress, await standIn("/__stand_in"));
  }
  const row = {
    label: LABEL,
    binary: BINARY,
    holdMs,
    atMs: pressAtMs,
    act,
    firstLoad,
    openReturnedAfterMs,
    // The press or the capture must come while the stand-in holds the page.
    actedAfterMs,
    actedInTime: actedAfterMs < holdMs,
    firstPressSent: pressing ? startsSince(before, afterPress) : null,
    invitationPagesAsked: afterPress.invitePages - before.invitePages,
    load,
    then: { page: then.page, fragmentLength: then.fragmentLength, buttonShown: then.buttonShown, invite: then.invite },
    pressThenSent: laterPress,
  };
  rows.push(row);
  console.log(JSON.stringify(row));
  await fs.writeFile(ROWS_FILE, JSON.stringify(rows, null, 2));
}
