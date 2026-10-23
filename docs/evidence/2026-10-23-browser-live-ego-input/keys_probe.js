// Presses every key name MASC sends to page.keyboard.press and records what ego answers.
const names = ["Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown",
  "ArrowLeft", "ArrowRight", "Home", "End",
  "Control+a", "Meta+a", "Alt+a", "Shift+a", "Control+Shift+ArrowLeft", "Meta+Shift+Home"];
const task = await taskSpace("masc-keys-probe");
const results = [];
try {
  const page = await task.newPage();
  await page.goto("data:text/html,<input id=k autofocus><script>window.seen=[];document.addEventListener('keydown',e=>window.seen.push(e.key+(e.isTrusted?'':'!')))</script>");
  await page.click("#k");
  for (const name of names) {
    const before = await page.evaluate("window.seen.length");
    let error = null;
    try { await page.keyboard.press(name); } catch (e) { error = String(e && e.message || e); }
    const seen = await page.evaluate(`window.seen.slice(${before})`);
    results.push({name, error, seen});
  }
} finally {
  await task.finish({keep: []});
}
console.log("probe-result " + JSON.stringify(results));
