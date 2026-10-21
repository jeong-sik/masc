import test,{before} from 'node:test'
import assert from 'node:assert/strict'
import {mkdtemp,readFile,writeFile,rm,stat} from 'node:fs/promises'
import {join,dirname} from 'node:path'
import {tmpdir} from 'node:os'
import {spawn} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import {Worker} from 'node:worker_threads'
import {captureFluidSound} from '../soundfont.mjs'
import {soundIdentity} from '../project-sound.mjs'
import {openFluidStream} from '../soundfont-stream.mjs'
import {openPcmOutput} from '../pcm-output.mjs'
import {openMidiInput} from '../midi-input.mjs'
import {openMonitorSession} from '../step-monitor-session.mjs'
import {openStepInput} from '../step-input.mjs'
import {openPracticeTake} from '../practice-take.mjs'
import {readPracticeFiles} from '../practice-source-files.mjs'
import {practicePartNames} from '../practice-source.mjs'
import {newEditor,editorCommand} from '../sequencer-editor.mjs'
import {phraseBacking} from '../phrase-backing.mjs'
import {newArrangement} from '../arrangement.mjs'
import {importArrangementPractice,saveArrangement,loadArrangement,importPracticeMidi,restorePracticeBacking} from '../arrangement-files.mjs'
import {arrangementEditor,arrangementCommand,arrangementPracticeSound,arrangementAction} from '../arrangement-editor.mjs'
import {startSoundArrangement} from '../arrangement-sound.mjs'
import {arrangementRoute} from '../arrangement-playback.mjs'
import {midiSourcePattern} from '../midi-source.mjs'
let sound
before(async()=>{sound=await captureFluidSound().promise})
const json=async p=>JSON.parse(await readFile(p,'utf8'))
const fixture=name=>fileURLToPath(new URL(`./fixtures/${name}.mjs`,import.meta.url))
async function recorded(run,{attributed=false,wrongIdentity=false}={}) {
  const root=await mkdtemp(join(tmpdir(),'fluid-practice-')),path=join(root,'take'),children=[]
  let editor=editorCommand(newEditor(),'program 33').editor
  editor={...editor,project:{...editor.project,sound}}
  const original=structuredClone(editor),messages=[],spawned=(...args)=>{const child=spawn(...args);children.push(child);return child}
  let sent=0,resolveSent
  const sounded=new Promise(resolve=>{resolveSent=resolve})
  const owner=openStepInput({source:'10',practice:true,recording:{path},audio:{sound,output:'owned',backing:phraseBacking(editor.project,'track-1')},
    getEditor:()=>editor,adoptEditor(){assert.fail('recording edited phrase')},enqueue:action=>Promise.resolve().then(action),
    openInput:options=>openMidiInput({...options,spawnProcess(_command,args,config){return spawned(process.execPath,[fixture('midi-input-owner'),attributed?'practice-attributed':'practice-clocked',...args],config)}}),
    openMonitor:options=>{
      const monitor=openMonitorSession({...options,
        openOutput:output=>openPcmOutput({...output,spawnProcess(_command,args,config){return spawned(process.execPath,[fixture('pcm-output'),'fluid-record',...args],config)}}),
        openSynth:(selected,config)=>{const synth=openFluidStream(selected,{...config,spawnProcess:spawned});return {...synth,render(frames,rows){messages.push(...structuredClone(rows));return synth.render(frames,rows)}}},
      })
      return {...monitor,diagnostics(){const report=monitor.diagnostics();if(wrongIdentity)report.sound.fontSHA256='0'.repeat(64);return report},
        async send(value){await monitor.send(value);if(++sent===4)resolveSent()}}
    },
  })
  try {
    await owner.ready
    if(attributed)await assert.rejects(owner.completion,/attributes/)
    else {
      await Promise.race([sounded,owner.completion.then(()=>{throw Error('input ended before four packets')})])
      owner.stop()
      if(wrongIdentity)await assert.rejects(owner.completion,/retirement/)
      else await owner.completion
    }
    assert.deepEqual(editor,original)
    assert.ok(children.every(c=>c.exitCode!==null||c.signalCode!==null))
    for(const c of children)assert.throws(()=>process.kill(c.pid,0),{code:'ESRCH'})
    const files=Object.fromEntries(Object.entries(practicePartNames).map(([role,name])=>[role,join(path,name)]))
    await run({root,path,files,messages,owner,original})
  }finally{owner.cancel();await owner.completion.catch(()=>{});await rm(root,{recursive:true,force:true})}
}
async function playback(project,sourceRoot,root,run) {
  const worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url)),jobs=new Map();let seq=0
  worker.on('message',row=>{const p=jobs.get(row.id);jobs.delete(row.id);row.ok?p?.resolve(row.result):p?.reject(Error(row.error))})
  worker.on('error',error=>{for(const p of jobs.values())p.reject(error)})
  const request=(value,issued)=>new Promise((resolve,reject)=>{const id=++seq;jobs.set(id,{resolve,reject});issued?.(id);worker.postMessage({...value,id})})
  const owner=startSoundArrangement({project,sourceRoot,directory:root,route:arrangementRoute({output:'owned'}),request,
    cancelRequest:request=>worker.postMessage({kind:'cancel',request}),run(){assert.fail('VST opened for recorded FluidSynth')}})
  try{await run(await owner.promise)}finally{await owner.dispose();await worker.terminate()}
}

test('actual SoundFont recording preserves original packets, signed frame fractions and bound retirement',()=>recorded(async({path,files,messages})=>{
  const receipt=await json(files.receipt),context=await json(files.context),rows=(await readFile(files.events,'utf8')).trim().split('\n').map(JSON.parse)
  assert.equal(receipt.status,'complete');assert.equal(receipt.packets,'4')
  assert.deepEqual(context.project.sound,sound)
  assert.deepEqual(receipt.monitorFinal.sound,soundIdentity(sound))
  assert.deepEqual(rows[0].nominalFrame,{numerator:'-1',denominator:'500'})
  assert.deepEqual(rows.map(r=>r.packet.words),[[0x43b54a00,0xabcdef01],[0x43953c00,0x90000000,0x43954000,0xffff0000],[0x43853c00,0x10000000],[0x43854000,0x20000000]])
  assert.deepEqual(rows.map(r=>r.packet.ordinal),['0','1','2','3'])
  assert.deepEqual(messages.slice(0,3).map(m=>m.bytes),[[0xc0,33],[0xb0,7,100],[0xb0,10,64]])
  const admitted=await readPracticeFiles(files)
  assert.equal(admitted.metadata.packets,'4');assert.equal(admitted.metadata.renderClock.sampleRate,48000)
  assert.equal((await stat(path)).mode&0o077,0)
  for(const file of Object.values(files))assert.equal((await stat(file)).mode&0o077,0)
}))

test('recorded font is default after portable reopen; override reset/undo keeps source bytes and exact region clocks',()=>recorded(async({root,path,files,original})=>{
  const bytes=await Promise.all(Object.values(files).map(p=>readFile(p))),projectPath=join(root,'first','song.json')
  const imported=await importArrangementPractice(newArrangement(),path,{projectPath})
  assert.equal(imported.project.assets[0].sound,undefined)
  let editor=arrangementCommand(arrangementEditor(imported.project),'practice-region asset-1 0 720001 1260000 3 2').editor
  const plain=structuredClone(editor.project)
  editor=arrangementPracticeSound(editor,'asset-1',{...sound,bankStyle:'gm'})
  editor=arrangementCommand(editor,'practice-sound-original asset-1').editor;assert.deepEqual(editor.project,plain)
  editor=arrangementAction(editor,{kind:'undo'});assert.equal(editor.project.assets[0].sound.bankStyle,'gm')
  editor=arrangementAction(editor,{kind:'redo'});assert.deepEqual(editor.project,plain)
  const portable=join(root,'portable','song.json');await saveArrangement(portable,editor.project,null,{sourceRoot:dirname(projectPath)})
  const loaded=await loadArrangement(portable);assert.deepEqual(loaded.project,plain)
  await playback(loaded.project,dirname(portable),root,async result=>{
    const plan=await json(result.path),asset=plan.assets[0],region=plan.regions[0],sourcePlan=await json(asset.path.replace('.wav','.json'))
    assert.equal(asset.realization.kind,'soundfont');assert.equal(asset.realization.fontSha256,sound.font.sha256)
    assert.equal(asset.realization.bankStyle,'mma');assert.equal(asset.sampleRate,48000)
    assert.deepEqual(sourcePlan.ports[0].events.slice(0,4).map(e=>e.bytes),[[0xc0,33],[0xb0,7,100],[0xb0,10,64],[0xb0,74,85]])
    assert.equal(region.repeat,2);assert.deepEqual(region.sourceClock,{start:'90000125',end:'247500125',denominator:'9000000000'})
    const pcm=await readFile(asset.path);let nonzero=0
    for(let i=44;i<pcm.length;i+=4){const sample=pcm.readFloatLE(i);assert.ok(Number.isFinite(sample));nonzero+=sample!==0}
    assert.ok(nonzero>0)
  })
  const restored=await restorePracticeBacking(plain,'asset-1',{sourceRoot:dirname(projectPath),directory:root})
  const expectedBacking=structuredClone(original.project);expectedBacking.title+=' backing';expectedBacking.tracks[0].muted=true
  assert.deepEqual(restored.project.assets.find(asset=>asset.id===restored.asset).phrase,expectedBacking)
  assert.deepEqual(await Promise.all(Object.values(files).map(p=>readFile(p))),bytes)
}))

test('editable MIDI variant initializes recorded program and captured font without rewriting original events',()=>recorded(async({root,path,files})=>{
  const before=await readFile(files.events),projectPath=join(root,'song.json')
  const imported=await importArrangementPractice(newArrangement(),path,{projectPath})
  const result=await importPracticeMidi(imported.project,'asset-1',{sourceRoot:dirname(projectPath),directory:root})
  const source=result.project.assets.at(-1).source,performance=midiSourcePattern(source)
  assert.deepEqual(source.sound,sound)
  assert.deepEqual(performance.events.filter(e=>e.kind==='channel').slice(0,4).map(e=>e.bytes),[[0xc0,33],[0xb0,7,100],[0xb0,10,64],[0xb0,74,85]])
  assert.equal(performance.notes.length,2)
  assert.deepEqual(await readFile(files.events),before)
}))

test('wrong monitor identity and unsupported projection preserve failed raw takes without admitting them',async()=>{
  for(const options of [{wrongIdentity:true},{attributed:true}])await recorded(async({files})=>{
    const receipt=await json(files.receipt),rows=(await readFile(files.events,'utf8')).trim().split('\n').map(JSON.parse)
    assert.equal(receipt.status,'failed');assert.ok(rows.length>0)
    if(options.attributed)assert.equal(rows[1].packet.words[0]&255,3)
    await assert.rejects(readPracticeFiles(files),/complete raw practice/)
  },options)
})

test('import rechecks every Fluid identity field even when the original content hashes remain valid',()=>recorded(async({files})=>{
  const receipt=await json(files.receipt)
  for(const change of [s=>{s.fontSHA256='0'.repeat(64)},s=>{s.engine.controlFrames++},s=>{s.engine.version+='-other'},s=>{s.bankStyle='gs'},s=>{delete s.kind},s=>{s.timing='exact'},s=>{delete s.engine}]) {
    const modified=structuredClone(receipt);change(modified.monitorFinal.sound)
    await writeFile(files.receipt,JSON.stringify(modified))
    await assert.rejects(readPracticeFiles(files),/retirement/)
  }
  await writeFile(files.receipt,JSON.stringify(receipt));await readPracticeFiles(files)
}))

test('an unbound built-in SoundFont cannot create a purported recorded synth context',async()=>{
  const root=await mkdtemp(join(tmpdir(),'unbound-practice-')),path=join(root,'take'),project=newEditor().project
  project.sound={kind:'soundfont'}
  try {
    await assert.rejects(openPracticeTake({path,project,sound:project.sound,track:'track-1',backing:phraseBacking(project,'track-1')}),/project-bound/)
    await assert.rejects(stat(path),{code:'ENOENT'})
  }finally{await rm(root,{recursive:true,force:true})}
})
