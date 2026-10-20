import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { openPracticeTake } from '../practice-take.mjs'
import { newProject } from '../sequencer-project.mjs'
import { phraseBacking } from '../phrase-backing.mjs'

const bytes = Buffer.from('practice take sound')
const sound = { kind:'vst', selection:{plugin_path:'/fixture.vst3',plugin_name:null,preset_path:null,name:'Fixture'},
  instrument:{identifier:'fixture-id',version:'1'},preset:{data:bytes.toString('base64'),sha256:createHash('sha256').update(bytes).digest('hex')} }
const clock = {kind:'clock',schemaVersion:1,device:{id:'owned',name:'Output'},sampleRate:48000,
  clock:{kind:'mach-host-time',numer:125,denom:3},anchor:{frame:'0',hostTime:'18446744073709000000'}}
const input = {kind:'midi-input',schemaVersion:1,protocol:2,source:{id:'10',name:'Keys'},clock:clock.clock}
const packet = {kind:'midi',protocol:2,source:'10',ordinal:'0',hostTime:'18446744073708999999',timestampOrigin:'packet',words:[0x43953c03,0x90012345]}
const context = path => { const project={...newProject(),sound}; return {path,project,sound,track:'track-1',backing:phraseBacking(project,'track-1')} }
const receipts = count => ({ inputFinal:{source:'10',success:true,admittedPackets:String(count),acknowledgedPackets:String(count),discardedPackets:'0'},
  monitorFinal:{pcm:{clock,nativeClosed:true,settled:true,final:{success:true}},worker:{closed:true,terminalReceived:true}} })
const json = async path => JSON.parse(await readFile(path,'utf8'))

test('private take retains frozen context, original attributed MIDI2 and exact pre-anchor fractions with content hashes', async () => {
  const root=await mkdtemp(join(tmpdir(),'practice-take-')),path=join(root,'take'),request=context(path)
  let take
  try {
    take=await openPracticeTake(request)
    request.project.title='caller mutation'
    await take.arm(input,clock);await take.append(packet)
    const result=await take.finish(receipts(1))
    assert.equal(result.status,'complete');assert.equal(take.diagnostics().status,'complete')
    assert.equal((await json(join(path,'context.json'))).project.title,'Phrase laboratory')
    const row=await json(join(path,'events.jsonl'))
    assert.deepEqual(row.packet,packet);assert.deepEqual(row.nominalFrame,{numerator:'-1',denominator:'500'})
    for(const part of Object.values(result.files)){
      assert.equal(createHash('sha256').update(await readFile(join(path,part.file))).digest('hex'),part.sha256)
      assert.equal((await stat(join(path,part.file))).mode&0o077,0)
    }
    assert.equal((await stat(path)).mode&0o077,0)
    assert.equal(JSON.stringify(take.diagnostics()).includes(sound.preset.data),false)
    await assert.rejects(take.append(packet),/not recording/)
  } finally {await rm(root,{recursive:true,force:true})}
})

test('existing directories are never reused; unarmed stop leaves a cancelled recoverable take', async () => {
  const root=await mkdtemp(join(tmpdir(),'practice-take-'))
  try {
    await writeFile(join(root,'sentinel'),'keep')
    await assert.rejects(openPracticeTake(context(root)),{code:'EEXIST'})
    assert.equal(await readFile(join(root,'sentinel'),'utf8'),'keep')
    const take=await openPracticeTake(context(join(root,'cancelled')))
    await assert.rejects(take.append(packet),/not recording/)
    assert.equal((await take.finish({})).status,'cancelled')
    assert.equal((await json(join(root,'cancelled','take.json'))).packets,'0')
  } finally {await rm(root,{recursive:true,force:true})}
})

test('clock mismatch, failed retirement and manifest publication failure cannot become successful takes', async () => {
  const root=await mkdtemp(join(tmpdir(),'practice-take-'))
  try {
    const take=await openPracticeTake(context(join(root,'failed')))
    await assert.rejects(take.arm({...input,clock:{...input.clock,numer:1}},clock),/disagree/)
    await take.arm(input,clock);await take.append(packet)
    await assert.rejects(take.finish(receipts(0)),/retirement/)
    assert.equal((await json(join(root,'failed','take.json'))).status,'failed')
    const collision=await openPracticeTake(context(join(root,'collision')))
    await collision.arm(input,clock)
    await writeFile(join(root,'collision','take.json'),'existing',{flag:'wx'})
    await assert.rejects(collision.finish(receipts(0)),{code:'EEXIST'})
    assert.equal(collision.diagnostics().status,'failed')
    assert.equal(await readFile(join(root,'collision','take.json'),'utf8'),'existing')
  } finally {await rm(root,{recursive:true,force:true})}
})
