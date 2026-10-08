import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { catalog, metrics, probe, usage, login } from './payloads.mjs'
const out=fileURLToPath(new URL('.',import.meta.url)), root=fileURLToPath(new URL('../..',import.meta.url))
const server=await createServer({root,configFile:root+'vite.config.ts',server:{host:'127.0.0.1',port:0,watch:null}})
await server.listen()
const browser=await chromium.launch({headless:true})
const page=await browser.newPage({viewport:{width:1280,height:950}});page.setDefaultTimeout(10000)
const errors=[],unexpected=[],requests=[],checks=[],held=[],pending=[]
let active='A',hold=false,failB=false,returned=false
page.on('pageerror',e=>errors.push(e.message))
await page.route('**/api/**',async route=>{
 const request=route.request(),path=new URL(request.url()).pathname
 if(!path.startsWith('/api/'))return route.continue()
 const reply=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
 if(path==='/api/v1/dashboard/dev-token')return reply({token:'synthetic-fixture-token',actor:'dashboard',role:'admin'})
 const name=active==='A'&&returned?'A-returned':active,failed=active==='B'&&failB
 requests.push({workspace:name,path,method:request.method()})
 let value
 switch(path){
  case '/api/v1/providers':value=catalog(name);break
  case '/api/v1/models/metrics':value=metrics(name);break
  case '/api/v1/runtime/resolved':value=usage(name==='A'?10:name==='B'?20:30);break
  case '/api/v1/dashboard/runtime-probe':value=probe(name);break
  case '/api/v1/runtime/official-client/probe':value=login(name);break
  default:unexpected.push(path);return reply({error:'unexpected route'},500)
 }
 if(hold&&active==='A'&&['/api/v1/models/metrics','/api/v1/dashboard/runtime-probe','/api/v1/runtime/official-client/probe'].includes(path)){
  held.push(path);await new Promise(resolve=>pending.push(resolve))
 }
 if(failed&&['/api/v1/models/metrics','/api/v1/dashboard/runtime-probe'].includes(path))return reply({error:'B reading unavailable'},503)
 return reply(value)
})
const click=name=>page.getByRole('button',{name,exact:true}).click()
const waitText=value=>page.waitForFunction(text=>document.body.innerText.includes(text),value)
const absent=async value=>assert.equal((await page.locator('body').innerText()).includes(value),false)
const waitHeld=()=>new Promise((resolve,reject)=>{
 const deadline=Date.now()+10000
 function check(){if(new Set(held).size===3)resolve();else if(Date.now()>deadline)reject(new Error('missing held fixture requests'));else setTimeout(check,10)}check()
})
try{
 await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-runtime-observation-workspace/fixture.html`)
 await waitText('Only-A-metric');await waitText('workspace-A-probe');await waitText('5시간 10% 사용')
 checks.push('initial A metrics, probe and provider usage through actual API decoders')
 hold=true
 await click('로그인 확인');await click('통계 새로 읽기');await click('refresh probe');await waitHeld()
 active='B';failB=true;await click('Fixture workspace B')
 await waitText('Account B');await waitText('통계를 읽지 못했습니다');await waitText('B reading unavailable')
 await absent('Only-A-metric');await absent('workspace-A-probe');await absent('5시간 10% 사용')
 checks.push('B failures never retain A metrics/probe/usage')
 hold=false;for(const release of pending.splice(0))release()
 await page.waitForFunction(()=>document.body.innerText.includes('로그인 미측정'))
 await absent('Only-A-login');await absent('Only-A-metric');await absent('workspace-A-probe')
 checks.push('late A observations and manual login result remain hidden')
 await page.screenshot({path:out+'workspace-b-errors.png',fullPage:true})
 failB=false;await click('통계 새로 읽기');await click('refresh probe')
 await waitText('Only-B-metric');await waitText('workspace-B-probe');await waitText('5시간 20% 사용')
 assert.match(await page.getByTestId('runtime-probe-catalog-spec').innerText(),/workspace-B-spec/)
 checks.push('explicit B retries restore current measurements and matching spec')
 await page.screenshot({path:out+'workspace-b-ready.png',fullPage:true})
 await click('Fixture withdraw authority');await waitText('작업공간을 확인한 뒤 통계를')
 await absent('Only-B-metric');await absent('workspace-B-probe');await absent('5시간 20% 사용')
 assert.equal(await page.getByRole('button',{name:'refresh probe',exact:true}).isDisabled(),true)
 const count=requests.length;await click('통계 새로 읽기');assert.equal(requests.length,count)
 checks.push('unconfirmed workspace withdraws readings and prevents requests')
 active='A';returned=true;await click('Fixture workspace A')
 await waitText('Only-A-returned-metric');await waitText('workspace-A-returned-probe');await waitText('5시간 30% 사용')
 await absent('Only-A-metric');await absent('workspace-A-probe');await absent('Only-A-login')
 checks.push('A return reads new observations without restoring old A')
 await page.setViewportSize({width:390,height:844})
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true)
 await page.screenshot({path:out+'workspace-a-returned-mobile.png',fullPage:true})
 checks.push('mobile has no horizontal overflow')
 assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[])
 assert.deepEqual(requests.filter(r=>r.method!=='GET').map(r=>r.path),['/api/v1/runtime/official-client/probe'])
 checks.push('one explicit login probe POST; no config writes, page errors or unexpected routes')
 await writeFile(out+'browser-result.json',JSON.stringify({passed:true,browser:browser.version(),scope:'Actual styled components and API parsers with synthetic HTTP. No real backend, CLI, full SPA, native TUI or deployment.',checks,requests,errors,unexpected},null,2)+'\n')
 console.log('PASS '+checks.length+' synthetic HTTP browser checks')
}catch(error){
 await writeFile(out+'browser-failure.json',JSON.stringify({error:String(error),body:await page.locator('body').innerText(),requests,errors,unexpected},null,2)+'\n');throw error
}finally{
 for(const release of pending.splice(0))release()
 await browser.close();await server.close()
}
