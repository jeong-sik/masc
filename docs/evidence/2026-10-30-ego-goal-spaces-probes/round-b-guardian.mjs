const fs = await import('node:fs/promises');
const root = "/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-probe-20261030-fLER";
const task = await taskSpace("masc-ego-two-space-20261030-a");
await fs.writeFile(root + "/guardian-space.json", JSON.stringify({ spaceId: task.spaceId, ownership: task.ownership, at: new Date().toISOString() }));
const page = task.page('p1');
await page.goto("http://127.0.0.1:54130/fixture.html");
const receipt = await page.click('#open', { label: 'probe B confirm hold' });
await fs.writeFile(root + "/guardian-ready.json", JSON.stringify({ receipt, info: await page.info(), at: new Date().toISOString() }));
let signal = null;
while (signal === null) {
  try { signal = await fs.readFile(root + "/guardian-signal.txt", "utf8"); }
  catch { await new Promise(r => setTimeout(r, 50)); }
}
const dismissed = await page.dismissDialog();
const info = await page.info();
const result = await page.evaluate(() => document.querySelector('#result').textContent);
await fs.writeFile(root + "/guardian-finished.json", JSON.stringify({ signal, dismissed, info, result, at: new Date().toISOString() }));
console.log(JSON.stringify({ guardian: true, spaceId: task.spaceId, dismissed, result }));
