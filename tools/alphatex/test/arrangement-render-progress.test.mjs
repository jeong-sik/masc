import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { createHash } from 'node:crypto'
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { newEditor, editorCommand, editorSound } from '../sequencer-editor.mjs'
import { arrangementFromPhrase } from '../phrase-arrangement.mjs'
import { editArrangement } from '../arrangement.mjs'
import { prepareArrangementVst } from '../arrangement-vst.mjs'

function project() {
  const bytes=Buffer.from('owned progress fixture preset')
  const sound={kind:'vst',selection:{plugin_path:'/fixture.vst3',plugin_name:null,preset_path:null,name:'Fixture'},
    preset:{data:bytes.toString('base64'),sha256:createHash('sha256').update(bytes).digest('hex')},instrument:{identifier:'fixture',version:'1'}}
  let editor=newEditor()
  for(const line of ['tempo 120','length 4','note C3 0 4 96'])editor=editorCommand(editor,line).editor
  const value=arrangementFromPhrase(editorSound(editor,sound).project).project, first=value.clips[0]
  return editArrangement(value,{kind:'region-add',lane:first.lane,asset:first.asset,name:'Second instance',position:3840,offset:0,extent:3840,repeat:1})
}

// A controlled child supplies native-shaped receipts; the product still runs
// its actual child-close, projection validation, instance and WAV consumers.
async function fixture(root,invalidProjection=false) {
  const executable=join(root,'projection.mjs'), exact=new URL('../exact-time.mjs',import.meta.url).href
  await writeFile(executable,`#!${process.execPath}
import {readFile,writeFile,mkdir} from 'node:fs/promises'; import {join} from 'node:path';
import {regionEdgeSeconds} from ${JSON.stringify(exact)};
const args=process.argv.slice(2), plan=JSON.parse(await readFile(args[args.indexOf('--file')+1],'utf8')), output=args[args.indexOf('--output')+1];
await mkdir(output); const parts=[];
for(const region of plan.regions){const source=plan.sources.find(value=>value.id===region.source);
 for(const port of new Set(source.events.filter(event=>event.seconds<region.sourceEnd || event.seconds===region.sourceEnd && region.sourceEnd===source.duration).map(event=>event.port))){
  const id=parts.length,startSeconds=regionEdgeSeconds(region.startNanoseconds,region.periodNanoseconds,0);
  parts.push({id,region:region.id,source:region.source,port,path:join(output,'part-'+id+'.jsonl'),startSeconds,
   duration:regionEdgeSeconds(region.startNanoseconds,region.periodNanoseconds,region.repeatCount)-startSeconds,eventCount:2,sha256:'a'.repeat(64)});
 }}
${invalidProjection?'parts.pop();':''}
await writeFile(join(output,'manifest.json'),JSON.stringify({schemaVersion:1,kind:'vst-render-parts',duration:plan.duration,parts}));
`,{mode:0o700})
  return executable
}
function wave(frames) {
  const bytes=Buffer.alloc(44+frames*4)
  bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16)
  bytes.writeUInt16LE(1,20);bytes.writeUInt16LE(2,22);bytes.writeUInt32LE(44100,24);bytes.writeUInt32LE(176400,28)
  bytes.writeUInt16LE(4,32);bytes.writeUInt16LE(16,34);bytes.write('data',36);bytes.writeUInt32LE(frames*4,40)
  return bytes
}

test('verified region/port total and accepted render receipts drive progress before mixing',async()=>{
  const root=await mkdtemp(join(tmpdir(),'masc-render-progress-')), events=[], operations=[]
  try{
    const executable=await fixture(root), original=project(), before=structuredClone(original)
    const result=await prepareArrangementVst(original,{directory:root,executable,onProgress:value=>events.push(value),run:request=>{
      operations.push({operation:request.operation,progress:events.at(-1)})
      return {cancel(){assert.fail('Unexpected cancellation')},promise:(async()=>{
        if(request.operation==='render')return {...request,preset_sha256:original.assets[0].source.sound.preset.sha256,
          frame_origin:Math.floor(request.origin_seconds*44100),frames:Math.ceil((request.origin_seconds+request.timeline_duration+request.tail_seconds)*44100)-Math.floor(request.origin_seconds*44100),peak:0.5}
        await writeFile(request.output_path,wave(request.frames))
        return {...request,instances:request.parts.length,peak:0.5,wav_sha256:'b'.repeat(64)}
      })()}
    }})
    assert.deepEqual(events,[{kind:'vst-projection'},{kind:'vst-render',completed:0,total:2},
      {kind:'vst-render',completed:1,total:2},{kind:'vst-render',completed:2,total:2},{kind:'vst-mix',completed:2,total:2}])
    assert.deepEqual(operations,[{operation:'render',progress:events[1]},{operation:'render',progress:events[2]},{operation:'mix',progress:events[4]}])
    assert.equal(JSON.parse(await readFile(result.path,'utf8')).kind,'wave-arrangement')
    assert.deepEqual(original,before)
  }finally{await rm(root,{recursive:true,force:true})}
})

test('unverified projection and rejected instance never publish invented completion or a mix',async()=>{
  for(const invalidProjection of [true,false]){
    const root=await mkdtemp(join(tmpdir(),'masc-render-refusal-')),events=[],operations=[]
    try{
      const executable=await fixture(root,invalidProjection)
      await assert.rejects(prepareArrangementVst(project(),{directory:root,executable,onProgress:value=>events.push(value),run:request=>{
        operations.push(request.operation)
        return {cancel(){},promise:Promise.resolve({})} // A render receipt that cannot be admitted.
      }}),invalidProjection?/omitted or added/:/preset does not match/)
      assert.deepEqual(events,invalidProjection?[{kind:'vst-projection'}]:[{kind:'vst-projection'},{kind:'vst-render',completed:0,total:2}])
      assert.deepEqual(operations,invalidProjection?[]:['render'])
      assert.deepEqual(await readdir(root),['projection.mjs'])
    }finally{await rm(root,{recursive:true,force:true})}
  }
})

test('actual worker progress carries the original request id and is not its terminal result',async()=>{
  const root=await mkdtemp(join(tmpdir(),'masc-worker-progress-')),worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url)),messages=[]
  try{
    const terminal=new Promise((resolve,reject)=>{
      worker.on('error',reject)
      worker.on('message',message=>{messages.push(message);if(message.kind!=='progress')resolve(message)})
    })
    const invalid=project();delete invalid.assets[0].source.sound;delete invalid.assets[0].phrase.sound
    worker.postMessage({id:73,kind:'prepare-vst',project:invalid,directory:root,sourceRoot:root})
    const result=await terminal
    assert.deepEqual(messages[0],{kind:'progress',id:73,progress:{kind:'vst-projection'}})
    assert.equal(result.id,73);assert.equal(result.ok,false)
    assert.equal(messages.length,2)
    assert.deepEqual(await readdir(root),[])
  }finally{await worker.terminate();await rm(root,{recursive:true,force:true})}
})
