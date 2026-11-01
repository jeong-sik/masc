const matches=(await listTaskSpaces()).filter(s=>s.id===6);
if(matches.length!==1 || matches[0].name!=="masc-keepers" || matches[0].ownership!=="agent")throw new Error("Original agent Space6 unavailable; no replacement");
const task=await taskSpace(6);
const report={startedAt:new Date().toISOString(),space:{id:task.spaceId,name:task.name,ownership:task.ownership},scope:"Exact source helper native SDK execution; not installed MASC",noInput:true};
const captureError=error=>({name:error?.name,message:String(error?.message??error),code:error?.code,timeoutMs:error?.timeoutMs,committed:error?.committed,waitUntil:error?.waitUntil});
const observe=async(fn)=>{try{return {returned:true,value:await fn()};}catch(error){return {returned:false,error:captureError(error)};}};
let ownedLabel;
async function stopNativeLoading(task, args) {
  // Loading can prevent every Page observation. Only the Space inventory and
  // native managed Page identity are used before the recovery command.
  const matches = (await task.tabs()).filter(row => row.label === args.label);
  if (matches.length !== 1)
    return {ok:false,before:true,error:'the managed Page is absent or ambiguous; inspect the same Space'};
  const tab = matches[0];
  if (typeof tab.targetId !== 'string' || tab.targetId.trim() === ''
      || (tab.openedBy !== 'agent' && tab.openedBy !== 'unknown'))
    return {ok:false,before:true,error:'the managed Page is no longer present; inspect the same Space'};
  const page = tab.page;
  if (!page || page.spaceId !== task.spaceId || page.label !== tab.label
      || page.targetId !== tab.targetId || page.openedBy !== tab.openedBy)
    return {ok:false,before:true,error:'native managed Page identity changed before recovery'};
  await page.cdp('Page.stopLoading');
  return {ok:true,value:{spaceId:task.spaceId,label:tab.label,targetId:tab.targetId,
    openedBy:tab.openedBy,method:'Page.stopLoading',returned:true}};
}
try {
 const page=await task.newPage();ownedLabel=page.label;report.ownedLabel=ownedLabel;
 await page.goto("http://127.0.0.1:60876"+'/ready');
 const rows=(await task.tabs()).filter(row=>row.label===ownedLabel);
 if(rows.length!==1 || rows[0].openedBy!=="agent")throw new Error("New owned Page identity is not canonical");
 const canonical=rows[0].page;
 report.identityBefore={spaceId:canonical.spaceId,label:canonical.label,targetId:rows[0].targetId,openedBy:rows[0].openedBy};
 report.normalRead=await observe(()=>canonical.snapshot());
 report.normalStop=await observe(()=>stopNativeLoading(task,{label:ownedLabel}));
 if(!report.normalStop.returned || report.normalStop.value?.ok!==true)throw new Error("Exact helper refused the normal owned Page");
 console.log('MASC_RECOVERY_PROGRESS '+JSON.stringify({stage:'normal_helper_passed',label:ownedLabel,at:new Date().toISOString()}));
 report.stalledNavigation=await observe(()=>canonical.goto("http://127.0.0.1:60876"+'/stall'));
 console.log('MASC_RECOVERY_PROGRESS '+JSON.stringify({stage:'native_navigation_returned',label:ownedLabel,outcome:report.stalledNavigation,at:new Date().toISOString()}));
 report.ordinaryReadDuringUncommitted=await observe(()=>canonical.info());
 report.loadingStop=await observe(()=>stopNativeLoading(task,{label:ownedLabel}));
 report.freshReadAfterStop={url:await observe(()=>canonical.url()),title:await observe(()=>canonical.title()),snapshot:await observe(()=>canonical.snapshot())};
 const after=(await task.tabs()).filter(row=>row.label===ownedLabel);
 report.identityAfter=after.map(row=>({spaceId:row.page.spaceId,label:row.label,targetId:row.targetId,openedBy:row.openedBy}));
} catch(error) {report.failure=captureError(error);}
finally {
 if(ownedLabel){
  report.cleanup=await observe(async()=>{
   const own=(await task.tabs()).filter(row=>row.label===ownedLabel);
   if(own.length===0)return {alreadyAbsent:true,label:ownedLabel};
   if(own.length!==1 || own[0].openedBy!=="agent")throw new Error("Owned Page identity changed; not closing another Page");
   const identity={spaceId:own[0].page.spaceId,label:own[0].label,targetId:own[0].targetId,openedBy:own[0].openedBy};
   await own[0].page.close();return {closed:true,identity};
  });
 }
 report.finalInventory=(await task.tabs()).map(row=>({label:row.label,targetId:row.targetId,openedBy:row.openedBy}));
 report.finishedAt=new Date().toISOString();console.log('MASC_RECOVERY_RESULT '+JSON.stringify(report));
}

