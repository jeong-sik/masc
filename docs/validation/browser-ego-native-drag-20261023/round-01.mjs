const fs = await import('node:fs/promises');
const directory='<evidence-directory>';
const task=await taskSpace('MASC shared native pointer drag 20261023');
await fs.writeFile(directory+'/space.json',JSON.stringify({spaceId:task.spaceId}));
const page=task.page('p1');
const html=`<!doctype html><meta charset="utf-8"><title>MASC ego native drag fixture</title>
<style>body{font:20px system-ui;background:#10192b;color:#edf6ff;padding:44px}h1{font-size:30px}.row{display:flex;align-items:center;gap:240px;margin:60px 20px}#source{width:140px;height:100px;background:#45b9ad;color:#092520;touch-action:none;cursor:grab;border:0;border-radius:16px;font:bold 20px system-ui}#target{width:230px;height:180px;border:3px dashed #7c94c9;border-radius:18px;display:grid;place-items:center}#status{font:22px monospace;color:#70e8bb}</style>
<h1>MASC · ego native pointer drag</h1><p>Move the card into the destination with native mouse input.</p>
<div class="row"><button id="source">Drag card</button><div id="target" role="region" aria-label="Destination">Destination</div></div>
<output id="status">Ready</output>
<script>window.events=[];let held=false;let start;
const source=document.querySelector('#source'),target=document.querySelector('#target'),status=document.querySelector('#status');
function record(e){events.push({type:e.type,trusted:e.isTrusted,buttons:e.buttons,x:e.clientX,y:e.clientY});}
source.addEventListener('pointerdown',e=>{record(e);held=true;start={x:e.clientX,y:e.clientY};source.setPointerCapture(e.pointerId);status.textContent='Dragging';});
source.addEventListener('pointermove',e=>{if(!held)return;record(e);source.style.transform='translate('+(e.clientX-start.x)+'px,'+(e.clientY-start.y)+'px)';});
source.addEventListener('pointerup',e=>{if(!held)return;record(e);held=false;const r=target.getBoundingClientRect();window.completed=e.clientX>=r.left&&e.clientX<=r.right&&e.clientY>=r.top&&e.clientY<=r.bottom;status.textContent=completed?'Dropped · native input verified':'Released outside destination';target.style.borderColor=completed?'#70e8bb':'#7c94c9';});</script>`;
await page.goto('data:text/html;charset=utf-8,'+encodeURIComponent(html));
console.log({taskSpaceId:task.spaceId,page:page.label});
console.log(await page.snapshot());
