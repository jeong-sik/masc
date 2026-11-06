// Runs the document script masc's ego peer sends for read mode html, in the
// order of lib/browser_ego_peer.ml on_page and evaluate.
const fn = __FN__;
const input = "null"; // Yojson.Safe.to_string `Null
const pageCall = (fn, input) => "(function(){ try { return {answer: (" + fn + ")(" + JSON.stringify(input) + ")}; } catch (error) { return {pageError: String(error && error.message || error)}; } })()";
const outputLimitBytes = 3 * (8 * 1024 * 1024 / 4) + 65536; // lib/browser_ego_peer.ml output_limit_bytes
const out = {};
const task = await taskSpace("masc-l1-read-html");
out.spaceId = task.spaceId;
const page = task.page("p1");
for (const name of ["index.html", "near.html", "big.html"]) {
  try {
    await page.goto("http://127.0.0.1:18768/" + name);
    const call = await page.evaluate(pageCall(fn, input));
    const line = JSON.stringify({ok: true, value: {label: "p1", answer: call}});
    const row = {lineBytes: Buffer.byteLength(line), withinOutputLimit: Buffer.byteLength(line) <= outputLimitBytes};
    if (call.pageError !== undefined) row.pageError = call.pageError;
    else if (typeof call.answer === "number") row.answerUnits = call.answer;
    else {
      const doc = JSON.parse(call.answer);
      row.answerJsonBytes = Buffer.byteLength(call.answer);
      row.htmlComplete = doc.htmlComplete;
      row.htmlUnavailableReason = doc.htmlUnavailableReason;
      row.htmlBytes = doc.html === null ? null : Buffer.byteLength(doc.html);
      row.htmlHead = doc.html === null ? null : doc.html.slice(0, 40);
      row.hasDocumentId = typeof doc.documentId === "string";
      if (doc.html !== null) {
        const expected = await page.evaluate(() => document.documentElement.outerHTML);
        row.equalsOuterHTML = expected === doc.html;
      }
    }
    out[name] = row;
  } catch (error) { out[name] = {error: String(error && error.message || error)}; }
}
await task.finish({keep: []});
console.log(JSON.stringify(out, null, 1));
