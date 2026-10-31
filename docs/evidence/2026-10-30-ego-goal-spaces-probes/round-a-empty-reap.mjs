const fs = await import('node:fs/promises');
const root = "/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-probe-20261030-fLER";
const events = [];
const log = (name, value = {}) => events.push({ name, at: new Date().toISOString(), ...value });
const listing = async () => (await listTaskSpaces()).map(s => ({ id: s.id, name: s.name, ownership: s.ownership }));

const emptied = await taskSpace("masc-ego-empty-reap-20261030-a");
const kept = await taskSpace("masc-ego-empty-reap-20261030-b");
log('opened', { emptied: emptied.spaceId, kept: kept.spaceId });

const p = emptied.page('p1');
await p.goto("https://example.com/");
log('emptied_page_open');
const k = kept.page('p1');
await k.goto("https://example.com/");
log('kept_page_open');

await p.close();
log('emptied_page_closed', { emptied: emptied.spaceId, kept: kept.spaceId });

for (let i = 1; i <= 24; i++) {
  await new Promise(r => setTimeout(r, 5000));
  try {
    const spaces = await listing();
    const ids = spaces.map(s => s.id);
    log('poll', { i, emptied_listed: ids.includes(emptied.spaceId), kept_listed: ids.includes(kept.spaceId), total: spaces.length });
  } catch (e) {
    log('poll_error', { i, error: String(e && e.message || e) });
  }
}
await fs.writeFile(root + "/round-a-events.json", JSON.stringify(events, null, 1));
console.log(JSON.stringify(events.filter(e => e.name === 'poll').slice(-4)));
