const fs = await import('node:fs/promises');
const root="/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-06111-gap-0_5cs8gq";const task=await taskSpace("MASC native SDK session revalidation 1792927279145738000");const page=task.page('p1');
await fs.writeFile(root+'/space.json',JSON.stringify({spaceId:task.spaceId,ownership:task.ownership}));
await page.goto("http://127.0.0.1:52052/"); const receipt=await page.click('#open',{label:'check native dialog session'});
await fs.writeFile(root+'/guardian-ready.json',JSON.stringify({receipt,info:await page.info()}));
let signal=null;while(signal===null){try{signal=await fs.readFile(root+'/signal.txt','utf8');}catch{await new Promise(r=>setTimeout(r,50));}}
const dismissed=await page.dismissDialog(); const info=await page.info();const result=await page.evaluate(()=>document.querySelector('#result').textContent);
await fs.writeFile(root+'/guardian-finished.json',JSON.stringify({dismissed,info,result}));console.log({guardian:true,dismissed,info,result});
