const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
(async () => {
 const root=process.argv[2], source=path.join(root,'experience.mp4');
 const bytes=fs.readFileSync(source);
 const browser=await chromium.launch({headless:true});
 const receipt={source_sha256:crypto.createHash('sha256').update(bytes).digest('hex'),scope:'Actual retained MP4 decoded and played by browser; not Dashboard acceptance',passed:false};
 try {
  const page=await browser.newPage({viewport:{width:1200,height:720}});
  await page.setContent('<body style="margin:0;background:#171717;display:grid;place-items:center;height:100vh"><video controls style="width:1152px;height:648px"></video></body>');
  await page.evaluate(data=>{const v=document.querySelector('video');v.src=data;v.load();},'data:video/mp4;base64,'+bytes.toString('base64'));
  await page.waitForFunction(()=>document.querySelector('video').readyState>=2);
  receipt.metadata=await page.evaluate(()=>{const v=document.querySelector('video');return {duration:v.duration,width:v.videoWidth,height:v.videoHeight,error:v.error?.message||null};});
  if(receipt.metadata.duration!==115||receipt.metadata.width!==1920||receipt.metadata.height!==1080||receipt.metadata.error)throw Error('Unexpected video metadata');
  await page.evaluate(()=>document.querySelector('video').play());
  await page.waitForFunction(()=>document.querySelector('video').currentTime>0.5);
  receipt.playback_observed=true;
  await page.evaluate(()=>document.querySelector('video').pause());
  receipt.frames=[];
  for(const t of [0,31,58,85,112]) {
   await page.evaluate(t=>new Promise(resolve=>{const v=document.querySelector('video');v.addEventListener('seeked',resolve,{once:true});v.currentTime=t;}),t);
   const state=await page.evaluate(()=>{const v=document.querySelector('video');return {time:v.currentTime,error:v.error?.message||null,readyState:v.readyState};});
   if(state.error||state.readyState<2)throw Error('Frame unavailable');
   const name=`video-browser-${t}.png`;await page.screenshot({path:path.join(root,name)});
   receipt.frames.push({...state,screenshot:name});
  }
  receipt.passed=true;
 }catch(e){receipt.error=String(e);process.exitCode=1;}
 finally{await browser.close();fs.writeFileSync(path.join(root,'video-browser.json'),JSON.stringify(receipt,null,2)+'\n');}
 console.log(JSON.stringify(receipt));
})();
