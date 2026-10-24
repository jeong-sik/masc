const fs=await import('node:fs/promises');const root="/tmp/masc-ego-session-dialog-20261024-HytWME";
const stage=async(name,value={})=>fs.writeFile(root+'/observer-stage.json',JSON.stringify({name,...value,at:new Date().toISOString()}));
await stage('before_taskSpace');const task=await taskSpace(4);await stage('before_info',{ownership:task.ownership});const page=task.page('p1');
const info=await page.info();await stage('after_info',{info});
const dismissed=await page.dismissDialog();await stage('after_dismiss',{info,dismissed});
const result=await page.evaluate(()=>document.querySelector('#result').textContent);const final=await page.info();
await stage('completed',{info,dismissed,result,final});console.log(JSON.stringify({observer:true,info,dismissed,result,final}));