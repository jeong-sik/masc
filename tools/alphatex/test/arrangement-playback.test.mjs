import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, readdir, stat, rm, chmod } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementWave } from '../arrangement-files.mjs'
import { prepareArrangementWave } from '../arrangement-playback.mjs'
import { importMidiSource } from '../midi-source.mjs'
function wave() {
  const bytes=Buffer.alloc(44+4800*2)
  bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16)
  bytes.writeUInt16LE(1,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(48000,24);bytes.writeUInt32LE(96000,28)
  bytes.writeUInt16LE(2,32);bytes.writeUInt16LE(16,34);bytes.write('data',36);bytes.writeUInt32LE(bytes.length-44,40)
  return bytes
}
async function workspace(run) {
  const root=await mkdtemp(join(tmpdir(),'masc-arrangement-playback-test-'))
  try {
    const input=join(root,'take.wav'),projectPath=join(root,'project.json'),bytes=wave()
    await writeFile(input,bytes)
    let project=(await importArrangementWave(newArrangement(),input,{projectPath})).project
    project=editArrangement(project,{kind:'lane-add',sourceKind:'wave',name:'Audio'})
    project=editArrangement(project,{kind:'region-add',name:'Trimmed',asset:'asset-1',lane:'lane-1',position:960,offset:1200,extent:2400,repeat:3})
    await run({root,input,bytes,project})
  } finally { await rm(root,{recursive:true,force:true}) }
}
test('private playback snapshots preserve frame trims and compressed finite repeats independently of editable assets',async()=>workspace(async({root,bytes,project})=>{
  project=editArrangement(project,{kind:'region-duplicate',id:'region-1',position:1920})
  const prepared=await prepareArrangementWave(project,{sourceRoot:root,directory:root})
  const plan=JSON.parse(await readFile(prepared.path,'utf8'))
  assert.equal(plan.kind,'wave-arrangement');assert.equal(plan.assets.length,1);assert.equal(plan.regions.length,2)
  assert.deepEqual(plan.regions.map(c=>[c.startSeconds,c.offsetFrames,c.frameCount,c.repeat]),[[.6,1200,2400,3],[1.2,1200,2400,3]])
  assert.equal(plan.duration,1.35)
  assert.deepEqual(await readFile(plan.assets[0].path),bytes)
  assert.notEqual((await stat(plan.assets[0].path)).ino,(await stat(join(root,project.assets[0].file))).ino)
  const changed=Buffer.from(bytes);changed[44]=1;await chmod(join(root,project.assets[0].file),0o600);await writeFile(join(root,project.assets[0].file),changed)
  assert.deepEqual(await readFile(plan.assets[0].path),bytes)
  const before=await readdir(root)
  await assert.rejects(prepareArrangementWave(project,{sourceRoot:root,directory:root}),/changed/)
  assert.deepEqual(await readdir(root),before)
}))
test('muted or solo-excluded MIDI never enters a WAV plan; active MIDI is explicitly refused',async()=>workspace(async({root,project})=>{
  const midi=Buffer.from('4d546864000000060000000101e04d54726b0000000d00903c648360803c0000ff2f00','hex')
  const source=importMidiSource(midi)
  project=editArrangement(project,{kind:'asset-add',asset:{id:'asset-2',name:'MIDI',kind:'midi',source}})
  project=editArrangement(project,{kind:'lane-add',sourceKind:'midi',name:'Keys'})
  project=editArrangement(project,{kind:'region-add',name:'Notes',asset:'asset-2',lane:'lane-2',position:0,offset:0,extent:480})
  await assert.rejects(prepareArrangementWave(project,{sourceRoot:root,directory:root}),/MIDI/)
  project=editArrangement(project,{kind:'lane-mute',id:'lane-2'})
  const prepared=await prepareArrangementWave(project,{sourceRoot:root,directory:root})
  assert.equal(JSON.parse(await readFile(prepared.path)).regions.length,1)
}))
test('cancellation and no audible regions create no playback artifacts',async()=>workspace(async({root,project})=>{
  const before=await readdir(root),controller=new AbortController();controller.abort()
  await assert.rejects(prepareArrangementWave(project,{sourceRoot:root,directory:root,signal:controller.signal}),{name:'AbortError'})
  await assert.rejects(prepareArrangementWave(newArrangement(),{sourceRoot:root,directory:root}),/No audible/)
  assert.deepEqual(await readdir(root),before)
}))
