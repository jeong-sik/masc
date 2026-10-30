const fs=await import('node:fs/promises');const root="/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-06111-gap-0_5cs8gq";
const stage=async(name,data={})=>fs.writeFile(root+'/observer-stage.json',JSON.stringify({name,...data,at:new Date().toISOString()}));
await stage('before_taskSpace');const task=await taskSpace(8);await stage('before_info',{ownership:task.ownership});const page=task.page('p1');
const info=await page.info();await stage('after_info',{info});const dismissed=await page.dismissDialog();const result=await page.evaluate(()=>document.querySelector('#result').textContent);const final=await page.info();
const receipt={info,dismissed,result,final};await stage('completed',receipt);await fs.writeFile(root+'/observer-finished.json',JSON.stringify(receipt));console.log(receipt);
