import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { listMidiSources, openMidiInput } from '../midi-input.mjs'
import { MidiSourcePicker } from '../midi-source-picker.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { stepControl, stepPacket, openStepInput } from '../step-input.mjs'
import { importMidiSource } from '../midi-source.mjs'
import { projectMidi } from '../sequencer-files.mjs'
midiFiles(JZZ)
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done});return {promise,resolve}}
const catalogFixture=fileURLToPath(new URL('./fixtures/midi-source-catalog.mjs',import.meta.url))
function catalog(mode,options={}) {
  let child
  const promise=listMidiSources({...options,spawnProcess(exe,args,config){
    assert.deepEqual(args,['--sources']);assert.equal(config.stdio[0],'ignore')
    child=spawn(process.execPath,[catalogFixture,mode,...args],config);return child
  }})
  return {promise,child}
}
test('read-only catalog uses a source-only query, validates stable identities and joins the child',async()=>{
  for(const mode of ['valid','empty']){
    const {promise,child}=catalog(mode),sources=await promise
    assert.notEqual(child.exitCode??child.signalCode,null)
    assert.deepEqual(sources,mode==='empty'?[]:[{id:'-17',name:'Keyboard'},{id:'99',name:'Second'}])
  }
  for(const mode of ['duplicate','bad-id','bad-name','invalid']){
    const {promise,child}=catalog(mode);await assert.rejects(promise)
    assert.notEqual(child.exitCode??child.signalCode,null)
  }
})
test('catalog cancellation returns only after actual child closure, and pre-abort never spawns',async()=>{
  const controller=new AbortController(),{promise,child}=catalog('wait',{signal:controller.signal})
  await new Promise(resolve=>child.stdout.once('data',resolve));controller.abort(new Error('menu closed'))
  await assert.rejects(promise,/menu closed/);assert.notEqual(child.exitCode??child.signalCode,null)
  await assert.rejects(listMidiSources({signal:controller.signal,spawnProcess(){assert.fail('pre-aborted catalog spawned')}}),/menu closed/)
  const late=new AbortController(),finished=catalog('valid',{signal:late.signal})
  finished.child.once('close',()=>late.abort(new Error('closed before catalog adoption')))
  await assert.rejects(finished.promise,/before catalog adoption/)
})
test('picker selection keeps source UID on refresh and never substitutes a vanished identity',async()=>{
  const chosen=[],catalogs=[[{id:'1',name:'A'},{id:'2',name:'B'}],[{id:'2',name:'B'},{id:'1',name:'A'}],[{id:'1',name:'A'}]]
  const picker=new MidiSourcePicker({selected:id=>chosen.push(id),discover:async()=>catalogs.shift()})
  await picker.open();picker.keypress('',{name:'down'});await picker.open()
  picker.keypress('',{name:'return'});assert.deepEqual(chosen,['2']);assert.equal(picker.view,null)
  const second=new MidiSourcePicker({selected:id=>chosen.push(id),discover:async()=>[{id:'2',name:'B'}]})
  await second.open();second.discover=async()=>[{id:'1',name:'A'}];await second.open()
  second.keypress('',{name:'return'});assert.deepEqual(chosen,['2'])
  second.keypress('',{name:'down'});second.keypress('',{name:'return'});assert.deepEqual(chosen,['2','1'])
})
test('dismissed/refreshed discovery cannot adopt stale results and settlement retains cancelled work',async()=>{
  const first=deferred(),second=deferred(),started=[],chosen=[]
  const picker=new MidiSourcePicker({selected:id=>chosen.push(id),discover:({signal})=>{started.push(signal);return started.length===1?first.promise:second.promise}})
  const old=picker.open();await Promise.resolve();const current=picker.open();await Promise.resolve()
  assert.equal(started[0].aborted,true);second.resolve([{id:'2',name:'Current'}]);await current
  first.resolve([{id:'1',name:'Old'}]);await old
  picker.keypress('',{name:'return'});assert.deepEqual(chosen,['2'])
  const wait=deferred();picker.discover=()=>wait.promise
  const pending=picker.open();await Promise.resolve();picker.close()
  let settled=false;const closed=picker.settled().then(()=>{settled=true});await Promise.resolve();assert.equal(settled,false)
  wait.resolve([{id:'3',name:'Dismissed'}]);await pending;await closed
  assert.equal(picker.view,null);assert.deepEqual(chosen,['2'])
})
test('rapid, failed and vanished-source refreshes retain the original source intent until explicit navigation',async()=>{
  const chosen=[],pending=deferred(),picker=new MidiSourcePicker({selected:id=>chosen.push(id),discover:async()=>[{id:'1',name:'A'},{id:'2',name:'B'}]})
  await picker.open();picker.keypress('',{name:'down'})
  picker.discover=()=>pending.promise;const first=picker.open();await Promise.resolve()
  picker.discover=async()=>[{id:'1',name:'A'}];await picker.open()
  pending.resolve([{id:'2',name:'Old'}]);await first
  picker.keypress('',{name:'return'});assert.deepEqual(chosen,[])
  await picker.open();picker.keypress('',{name:'return'});assert.deepEqual(chosen,[])
  picker.discover=async()=>{throw new Error('catalog unavailable')};await picker.open()
  picker.discover=async()=>[{id:'1',name:'A'},{id:'2',name:'B'}];await picker.open()
  picker.keypress('',{name:'return'});assert.deepEqual(chosen,['2'])
  await picker.open();picker.keypress('',{name:'return'});assert.deepEqual(chosen,['2','1'])
})
test('explicit step lengths/rests preserve notes and history and produce dotted/triplet input at exact ticks',()=>{
  let editor=editorCommand(newEditor(),'note C4 0 1 70').editor
  const original=editor.project,undo=editor.undo
  editor=stepControl(editor,{kind:'step-length',value:'1/3'})
  assert.equal(editor.duration,320);assert.equal(editor.project,original);assert.equal(editor.undo,undo)
  editor=stepControl(editor,{kind:'step-rest',value:'1.5'})
  assert.equal(editor.tick,1440);assert.equal(editor.project,original)
  const packet={kind:'midi',protocol:2,source:'10',timestampOrigin:'packet',words:[0x40903e00,0xffff0000,0x40803e00,0]}
  editor=stepPacket(editor,null,packet).editor
  assert.deepEqual(editor.project.tracks[0].notes.map(n=>[n.pitch,n.start,n.duration]),[[60,0,960],[62,1440,320]])
  const smf=new JZZ.MIDI.SMF(projectMidi(editor.project))
  assert.deepEqual([...smf[1]].filter(e=>e.isNoteOn()).map(e=>[e.tt,e.getNote()]),[[0,60],[1440,62]])
  assert.equal(stepControl(editor,{kind:'step-rest'}).tick,2080)
  for(const value of ['0','1/7','-1','NaN','1/0','9007199254740992','1e3'])assert.throws(()=>stepControl(editor,{kind:'step-length',value}))
  assert.throws(()=>stepControl({...editor,tick:editor.project.length},{kind:'step-rest'}))
})
test('source step controls retain original PPQ/SMPTE ticks, allow point input, and do not edit existing notes',()=>{
  for(const smpte of [false,true]){
    const file=smpte?new JZZ.MIDI.SMF(1,25,40):new JZZ.MIDI.SMF(1,1001)
    file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(4,60,80)).add(1001,JZZ.MIDI.noteOff(4,60,20)))
    let editor=newEditor(importMidiSource(file.toUint8Array())),original=editor.project
    editor=stepControl(editor,{kind:'step-length',value:smpte?'1/4':'1/7'})
    assert.equal(editor.duration,smpte?10:143)
    editor=stepControl(editor,{kind:'step-rest'})
    assert.equal(editor.tick,smpte?10:143);assert.equal(editor.project,original)
    assert.equal(stepControl(editor,{kind:'step-length',value:'0'}).duration,0)
    assert.throws(()=>stepControl(editor,{kind:'step-length',value:smpte?'1/3':'0.5'}),/whole source ticks/)
  }
})
test('armed controls refuse held chords/drain but close preserves already admitted control decisions',async()=>{
  const fixture=fileURLToPath(new URL('./fixtures/midi-input-owner.mjs',import.meta.url)),held=deferred()
  let editor=newEditor(),task=Promise.resolve()
  const input=openStepInput({source:'10',getEditor:()=>editor,adoptEditor:next=>{editor=next},
    enqueue(action){const decision=task.then(action);task=decision.catch(()=>{});return decision},onState:state=>{if(state.held)held.resolve()},
    openInput:options=>openMidiInput({...options,spawnProcess(exe,args,config){return spawn(process.execPath,[fixture,'step-held',...args],config)}})})
  await input.ready;await held.promise
  for(const action of [{kind:'step-length',value:'1/2'},{kind:'step-rest'}])assert.throws(()=>input.control(action),/Release all keys/)
  assert.equal(editor.project.tracks[0].notes.length,0);input.stop();await input.completion
  let fakeOptions,finish
  const fake=openStepInput({source:'10',getEditor:()=>editor,adoptEditor:next=>{editor=next},enqueue:action=>action(),openInput(options){fakeOptions=options;return {ready:Promise.resolve(),completion:new Promise(resolve=>{finish=resolve}),stop(){}}}})
  fake.stop({admittedControls:true});editor=fake.control({kind:'step-length',value:'1/2'});assert.equal(editor.duration,480)
  fake.stop();assert.throws(()=>fake.control({kind:'step-rest'}),/draining/)
  finish();await fake.completion
})
