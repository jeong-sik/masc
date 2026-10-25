const fs=await import('node:fs/promises');const task=await taskSpace(8);const page=task.page('p1');
const screenshot=await page.screenshot({path:"/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-06111-gap-0_5cs8gq/dialog-gap-final.png"});await task.finish({keep:[]});
await fs.writeFile("/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-06111-gap-0_5cs8gq/cleanup.json",JSON.stringify({spaceId:8,screenshot,finished:true,finishCalls:1,remainingSpaces:await listTaskSpaces()}));console.log({spaceId:8,screenshot,finished:true});
