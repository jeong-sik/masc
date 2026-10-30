// Actual ExpandableTextarea in Chromium; controlled initial input before passive effects.
import assert from 'node:assert/strict'
import {createHash} from 'node:crypto'
import {createRequire} from 'node:module'
import {readFile, mkdir, writeFile} from 'node:fs/promises'
import {resolve} from 'node:path'
import {pathToFileURL} from 'node:url'
const root = resolve(process.argv[2])
const out = resolve(process.argv[3])
await mkdir(out)
const require = createRequire(resolve(root, 'package.json'))
const {createServer} = await import(pathToFileURL(require.resolve('vite')).href)
const {chromium} = require('playwright')
const modulePath = '/src/components/common/expandable-textarea.ts'
const candidate = await readFile(resolve(root, '.' + modulePath), 'utf8')
const main = await readFile(new URL('./main-expandable-textarea.ts', import.meta.url), 'utf8')
const variants = ['main', 'fixed']
const results = []
const vite = await createServer({configFile:false, root, cacheDir:resolve(out,'vite-cache'), logLevel:'error',
  server:{host:'127.0.0.1',port:0},
  plugins:[{name:'effect-order-probe',enforce:'pre',
    transform(code,id) {
      if (!id.includes(modulePath) || !id.includes('probe=')) return
      const variant = new URL('http://fixture/' + id).searchParams.get('probe')
      let source = variant === 'main' ? main : candidate
      source = source.replace('  const [expanded', "  ;(window as any).probeTrace.push({kind:'render',time:performance.now(),value,local})\n  const [expanded")
      source = source.replace('    setLocal(value)', "    ;(window as any).probeTrace.push({kind:'sync-effect',time:performance.now(),value})\n    setLocal(value)")
      return {code:source,map:null}
    },
    configureServer(server) {
      server.middlewares.use(async(req,res,next)=>{
        const url = new URL(req.url,'http://fixture')
        if(!url.pathname.startsWith('/__probe/')) return next()
        const variant = url.pathname.slice('/__probe/'.length)
        if (!variants.includes(variant)) {res.statusCode=400;res.end();return}
        res.setHeader('Content-Type','text/html')
        res.end(await server.transformIndexHtml(url.pathname,`<!doctype html><meta charset="utf-8"><title>Textarea effect-order probe</title><style>body{background:#171c26;color:#eee;font:20px sans-serif;padding:24px}textarea{width:520px;height:120px;font:20px monospace}button{margin:12px}</style><h1>First input after mount</h1><p>Controlled component fixture; no deployed server.</p><div id="root"></div><script type="module">
          import {html} from 'htm/preact';import {render} from 'preact';
          import {ExpandableTextarea} from '${modulePath}?probe=${variant}';
          window.probeTrace=[];window.committed=[];window.inputs=[];
          const descriptor=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value');
          Object.defineProperty(HTMLTextAreaElement.prototype,'value',{...descriptor,set(next){
            window.probeTrace.push({kind:'dom-set',time:performance.now(),from:descriptor.get.call(this),value:next});
            descriptor.set.call(this,next);
          }});
          let parentValue='Original instructions';
          const mount=()=>render(html\`<\${ExpandableTextarea} value=\${parentValue} label="Instructions" onChange=\${v=>{window.committed.push(v);parentValue=v;mount()}} onInput=\${v=>window.inputs.push(v)}/>\`,document.getElementById('root'));
          window.mountAndType=()=>{
            mount();
            const el=document.querySelector('textarea');el.focus();el.value='First instructions';
            window.probeTrace.push({kind:'input-dispatch',time:performance.now(),value:el.value});
            el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'First instructions'}));
          };
          window.reset=()=>{parentValue='Server reset';mount()};
          window.ready=true;
          </script>`))
      })
    }
  }]
})
let browser
try {
  await vite.listen()
  const origin='http://127.0.0.1:'+vite.httpServer.address().port
  browser=await chromium.launch({args:['--no-sandbox']})
  for(const variant of variants) {
    const page=await browser.newPage()
    const errors=[];page.on('pageerror',e=>errors.push(e.message))
    await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort())
    await page.goto(origin+'/__probe/'+variant)
    await page.waitForFunction(()=>window.ready)
    await page.evaluate(()=>window.mountAndType())
    // Let passive effects run; observation has a bounded readiness wait.
    await page.waitForFunction(()=>window.probeTrace.some(e=>e.kind==='sync-effect'),{},{timeout:3000})
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))))
    const afterInput=await page.locator('textarea').inputValue()
    await page.locator('textarea').blur()
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))))
    const beforeReset=await page.evaluate(()=>({trace:window.probeTrace,committed:window.committed,inputs:window.inputs}))
    await page.screenshot({path:resolve(out,variant+'.png')})
    await page.evaluate(()=>window.reset())
    await page.waitForFunction(()=>document.querySelector('textarea').value==='Server reset',{},{timeout:3000})
    const result={variant,afterInput,afterBlur:beforeReset.committed,afterReset:await page.locator('textarea').inputValue(),errors,...beforeReset}
    results.push(result)
    await page.close()
  }
  assert.equal(results[0].afterInput,'Original instructions')
  assert.equal(results[1].afterInput,'First instructions')
  assert.deepEqual(results[1].afterBlur,['First instructions'])
  assert.ok(results.every(r=>r.afterReset==='Server reset' && r.errors.length===0))
} catch(e) {process.exitCode=1;results.push({error:e.stack})}
finally {
  await browser?.close();await vite.close()
  await writeFile(resolve(out,'receipt.json'),JSON.stringify({scope:'Controlled same-task input immediately after mount of actual component; no deployed server, passive scheduling unmodified.',sources:{mainRevision:'727fc531230d48f601bc78c7b33f6ad26c5de654',mainSha256:createHash('sha256').update(main).digest('hex'),fixedSha256:createHash('sha256').update(candidate).digest('hex'),sourceUnchanged:candidate===await readFile(resolve(root,'.'+modulePath),'utf8')},results},null,2)+'\n')
}
console.log(JSON.stringify(results))
