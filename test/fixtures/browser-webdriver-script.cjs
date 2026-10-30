"use strict";
// Primitive execute/sync fixture: evaluate the supplied product script rather
// than manufacture BrowserRead or BrowserInteract response objects.
const vm = require("node:vm");
const { script, args } = JSON.parse(process.argv[2]);
if (typeof script !== "string" || !Array.isArray(args)) {
  throw new Error("expected WebDriver script and args");
}
const window = {
  scrollX: 0, scrollY: 0,
  scrollBy({ left, top }) { this.scrollX += left; this.scrollY += top; },
};
const context = {
  window,
  document: { title: "Probe", body: { innerText: "Observed page" } },
  location: { href: "https://example.org/probe" },
  args,
};
const result = vm.runInNewContext(
  `(function () {${script}\n}).apply(null, args)`, context,
);
process.stdout.write(JSON.stringify(result));
