const fs=await import('node:fs/promises');
const root='/tmp/masc-ego-round-download-20261024-uJyJz5';
const previous=JSON.parse(await fs.readFile(root+'/proof.json','utf8'));
const task=await taskSpace(4);const page=task.page('p1');
const record={spaceId:task.spaceId,ownership:task.ownership,page:page.label,info:await page.info(),temporaryExists:await fs.stat(previous.temporary).then(s=>({exists:true,size:s.size}),e=>({exists:false,code:e.code})),savedExists:await fs.stat(previous.saved).then(s=>({exists:true,size:s.size}),e=>({exists:false,code:e.code}))};
await fs.writeFile(root+'/round2-record.json',JSON.stringify(record,null,2));console.log(JSON.stringify(record));
