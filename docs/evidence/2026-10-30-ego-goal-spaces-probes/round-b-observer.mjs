const fs = await import('node:fs/promises');
const root = "/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-probe-20261030-fLER";
const stage = async (name, value = {}) =>
  fs.writeFile(root + "/observer-stage-" + name + ".json", JSON.stringify({ name, at: new Date().toISOString(), ...value }));

while (true) {
  try { await fs.readFile(root + "/guardian-ready.json", "utf8"); break; }
  catch { await new Promise(r => setTimeout(r, 50)); }
}
await stage('guardian_hold_seen');

const task = await taskSpace("masc-ego-two-space-20261030-b");
await stage('task_open', { spaceId: task.spaceId, ownership: task.ownership });
const page = task.page('p1');
await page.goto("http://127.0.0.1:54130/fixture.html");
await stage('goto_done', { url: await page.url() });
const info = await page.info();
await stage('info_done', { title: info.title });
const result = await page.evaluate(() => document.querySelector('#result').textContent);
await stage('evaluate_done', { result });
const tabs = await task.tabs();
await stage('tabs_done', { count: tabs.length });
const t0 = Date.now();
const info2 = await page.info();
await stage('second_info_done', { ms: Date.now() - t0, url: info2.url });
console.log(JSON.stringify({ observer: true, spaceId: task.spaceId, result, tabs: tabs.length }));
