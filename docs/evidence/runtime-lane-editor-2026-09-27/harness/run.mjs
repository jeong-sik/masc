// Manual source-component proof. All API traffic is synthetic and intercepted.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createServer as createNetServer} from 'node:net';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
if(process.argv.length!==4)throw new Error('Usage: node run.mjs CHECKOUT NEW_OUTPUT_DIRECTORY');
const checkout=path.resolve(process.argv[2]);
const out=path.resolve(process.argv[3]);
const dashboard=path.join(checkout,'dashboard');
const harness=path.dirname(fileURLToPath(import.meta.url));
const sourceCommit='af7a80c4b87b9729a468e62f70f0c033cf1d6d64';
const git=(...args)=>execFileSync('git',args,{cwd:checkout,encoding:'utf8'}).trim();
// Later documentation-only heads are allowed; product source and lock must match.
git('diff','--exit-code',sourceCommit,'--','dashboard/src','dashboard/pnpm-lock.yaml');
const require=createRequire(path.join(dashboard,'package.json'));
const {chromium}=require('playwright');
const {createServer}=await import(pathToFileURL(require.resolve('vite')).href);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const fixtures=JSON.parse(await fs.readFile(path.join(harness,'fixtures.json'),'utf8'));
await fs.mkdir(out,{recursive:false});
const temporary=await fs.mkdtemp(path.join(dashboard,'.runtime-lane-proof-'));
for(const file of ['entry.ts','index.html'])await fs.copyFile(path.join(harness,file),path.join(temporary,file));
let server,browser;
let order=['rt-a','rt-b','rt-c']; let revision='a'.repeat(64); const requests=[]; const errors=[];
try {
 const listener=createNetServer();
 await new Promise((resolve,reject)=>{listener.once('error',reject);listener.listen(0,'127.0.0.1',resolve)});
 const requestedPort=listener.address().port;
 await new Promise((resolve,reject)=>listener.close(error=>error?reject(error):resolve()));
 server=await createServer({root:dashboard,configFile:false,base:'/',server:{host:'127.0.0.1',port:requestedPort,strictPort:true},optimizeDeps:{include:['preact','htm/preact','@preact/signals']}});
 await server.listen();
 const port=server.httpServer.address().port;
 browser=await chromium.launch({headless:true});
 const page=await browser.newPage({viewport:{width:1440,height:1100},locale:'ko-KR'});
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*', async route=>{
  const u=new URL(route.request().url());
  if(u.hostname!=='127.0.0.1')return route.abort();
  if(!u.pathname.startsWith('/api/')&&u.pathname!=='/dev-token'&&u.pathname!=='/mcp')return route.continue();
  const method=route.request().method();requests.push({method,path:u.pathname,body:route.request().postData()});
  let status=200, body;
  if(u.pathname==='/api/v1/dashboard/runtime-defaults')body=fixtures.defaults;
  else if(u.pathname==='/api/v1/runtime/resolved')body=fixtures.resolved;
  else if(u.pathname==='/api/v1/providers')body=fixtures.providers;
  else if(u.pathname==='/api/v1/runtime/config/raw')body={ok:true,path:'fixture/config/runtime.toml',file_name:'runtime.toml',source_revision:revision,source_text:'[runtime]\ndefault = "rt-a"\n[runtime.lanes.coding]\ncandidates = '+JSON.stringify(order)+'\n',reloaded:false,provider_protocols:[{protocol:'openai-compatible-http',transport:'endpoint',semantics:'http_provider',credential_policy:'optional',requires_non_interactive:false,provider_fields:[],required_provider_fields:[]}]};
  else if(u.pathname==='/api/v1/runtime/config/routing'){status=409;body={error:'runtime.toml changed since the lane candidates were read (synthetic fixture conflict); reload before editing'};}
  else {status=503;body={error:'synthetic fixture: unrelated surface unavailable'};}
  return route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)});
 });
 await page.goto(`http://127.0.0.1:${port}/${path.basename(temporary)}/index.html`);
 await page.getByTestId('settings-nav-routing').click();
 const up=page.getByTestId('runtime-lane-coding-up-rt-b');
 await up.waitFor({state:'visible',timeout:5000}).catch(async e=>{await fs.writeFile(out+'/failed-diagnostic.json',JSON.stringify({requests,errors,text:await page.locator('body').innerText()},null,2));await page.screenshot({path:out+'/failed-screen.png',fullPage:true});throw e;});
 await page.waitForFunction(()=>!document.querySelector('[data-testid="runtime-lane-coding-up-rt-b"]').disabled);
 const ids=()=>page.getByTestId('runtime-lane-coding').locator('.rt-fo-id').allTextContents();
 assert.deepEqual(await ids(),['rt-a','rt-b','rt-c']);
 await page.getByTestId('runtime-lane-coding').scrollIntoViewIfNeeded();
 await page.screenshot({path:out+'/01-lane-editor.png',fullPage:true});
 order=['rt-c','rt-a','rt-b']; revision='b'.repeat(64);
 await up.click();
 await page.getByTestId('runtime-lane-message').filter({hasText:'다른 곳에서 바뀌어 편집을 보내지 않았습니다'}).waitFor();
 assert.equal(requests.filter(x=>x.method==='POST'&&x.path.endsWith('/routing')).length,0);
 assert.deepEqual(await ids(),order);
 await page.screenshot({path:out+'/02-stale-click-refused.png',fullPage:true});
 await up.click();
 await page.getByTestId('runtime-lane-message').filter({hasText:'synthetic fixture conflict'}).waitFor();
 const posts=requests.filter(x=>x.method==='POST'&&x.path.endsWith('/routing'));
 assert.equal(posts.length,1);
 assert.deepEqual(JSON.parse(posts[0].body),{lane:'coding',action:'set',runtime_ids:['rt-c','rt-b','rt-a'],expected_source_revision:revision});
 await page.screenshot({path:out+'/03-server-conflict.png',fullPage:true});
 assert.deepEqual(await ids(),order);
 assert.deepEqual(errors,[]);
 await fs.writeFile(out+'/receipt.json',JSON.stringify({source_commit:sourceCommit,checkout_head:git('rev-parse','HEAD'),scope:'production Settings component and API client in Chromium; synthetic intercepted HTTP; no backend or deployment proof',browser:browser.version(),passed:['initial_lane_order','stale_click_zero_posts','fresh_order_rendered','retry_exact_CAS_body','HTTP_409_visible','conflict_does_not_show_saved_order'],requests,errors},null,2));
 const files=['dashboard/src/components/settings-surface.ts','dashboard/src/api/dashboard-runtime.ts','dashboard/src/lib/runtime-toml-config.ts','dashboard/src/main.ts','dashboard/pnpm-lock.yaml'];
 const productionSources={};for(const file of files)productionSources[file]=sha(await fs.readFile(path.join(checkout,file)));
 const fixtureFiles={};for(const file of ['run.mjs','entry.ts','index.html','fixtures.json'])fixtureFiles[file]=sha(await fs.readFile(path.join(harness,file)));
 const artifacts={};for(const file of ['01-lane-editor.png','02-stale-click-refused.png','03-server-conflict.png','receipt.json'])artifacts[file]=sha(await fs.readFile(path.join(out,file)));
 await fs.writeFile(path.join(out,'source-identity.json'),JSON.stringify({source_commit:sourceCommit,checkout_head:git('rev-parse','HEAD'),dashboard_source_tree:git('rev-parse',sourceCommit+':dashboard/src'),production_sources:productionSources,harness:fixtureFiles,artifacts},null,2)+'\n');
 console.log('BROWSER PASS '+out);
} finally {
 await browser?.close();
 await server?.close();
 await fs.rm(temporary,{recursive:true,force:true});
}
