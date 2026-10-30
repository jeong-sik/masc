const fs = await import('node:fs/promises');
const root = "/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-probe-20261030-fLER";
const names = ["masc-ego-empty-reap-20261030-a", "masc-ego-empty-reap-20261030-b",
  "masc-ego-two-space-20261030-a", "masc-ego-two-space-20261030-b"];
const out = {};
const listed = new Set((await listTaskSpaces()).map(s => s.name));
for (const name of names) {
  if (!listed.has(name)) { out[name] = { absent: true }; continue; }
  try {
    const t = await taskSpace(name);
    const finish = await t.finish({ keep: [] });
    out[name] = { ok: true, spaceId: t.spaceId, finish };
  } catch (e) { out[name] = { ok: false, error: String(e && e.message || e) }; }
}
await fs.writeFile(root + "/cleanup.json", JSON.stringify(out, null, 1));
console.log(JSON.stringify(out));
