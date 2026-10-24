const fs=await import('node:fs/promises');
const root="/tmp/masc-ego-session-dialog-20261024-HytWME";const task=await taskSpace(4);if(task.ownership!=='agent')throw Error('owned goal space unavailable');const page=task.page('p1');
const before=await page.info();if(before.dialog)throw Error('preexisting dialog; leave it unchanged');
await page.goto("http://localhost:54983/");const receipt=await page.click('#open',{label:'open owned audit confirm'});
await fs.writeFile(root+'/guardian-ready.json',JSON.stringify({spaceId:task.spaceId,receipt,info:await page.info()}));
let signal=null;while(signal===null){try{signal=await fs.readFile(root+'/guardian-signal.txt','utf8');}catch{await new Promise(r=>setTimeout(r,50));}}
let recovery=null;if(signal==='dismiss'){recovery={dismissed:await page.dismissDialog(),info:await page.info(),result:await page.evaluate(()=>document.querySelector('#result').textContent)};}
await fs.writeFile(root+'/guardian-finished.json',JSON.stringify({signal,recovery}));console.log(JSON.stringify({guardian:true,signal,recovery}));