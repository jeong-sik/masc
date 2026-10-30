const fs=await import('node:fs/promises');
const dataset=JSON.parse(await fs.readFile('/tmp/masc-schedule-drain-qa-20261025/dataset.json','utf8'));
const task=await taskSpace(45);const page=task.page('p1');
const base=new URL(await page.url());const results=[];
for(const [key,state,file] of [
 ['completed:unprojected','settling','completed-unprojected.png'],
 ['failed:projected','failed','failed-projected.png'],
 ['completed:unreadable_receipt','read_error','unreadable-receipt.png'],
 ['transferred:projected','pending','transferred-projected.png'],
]){
 const url=new URL(base);url.searchParams.set('case',key);
 if(key!=='completed:unprojected')await page.goto(url.href);
 await page.waitForSelector('#case-status[data-state="'+state+'"]');
 await page.waitForSelector('[data-schedule-keeper-queue-evidence="'+dataset[key].row.keeper_queue_evidence.projection_status+'"]');
 await page.hover('[data-schedule-keeper-queue-evidence]',{label:'inspect exact queue evidence'});
 const observed=await page.evaluate(()=>({
  ...window.__scheduleProducedRow,
  kpi:document.querySelector('[data-testid="schedule-kpi-queue-miss"]')?.textContent,
  exact:document.querySelector('[data-keeper-queue-evidence-row="post_id"]')?.textContent,
  queueVisible:(()=>{const b=document.querySelector('[data-schedule-keeper-queue-evidence]').getBoundingClientRect();return b.top<innerHeight&&b.bottom>0})(),
  reaction:document.querySelector('[data-schedule-keeper-reaction-evidence]')?.getAttribute('data-schedule-keeper-reaction-evidence'),
 }));
 if(observed.state!==state||observed.misses!==0||!observed.exact?.includes(dataset[key].row.keeper_queue_evidence.post_id)||!observed.queueVisible)throw new Error(JSON.stringify(observed));
 observed.screenshot=await page.screenshot({path:'/tmp/masc-schedule-drain-qa-20261025/'+file});results.push(observed);
}
await fs.writeFile('/tmp/masc-schedule-drain-qa-20261025/browser-observed.json',JSON.stringify(results,null,2)+'\n');
console.log(results);console.log(await page.snapshot());
