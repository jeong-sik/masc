import test,{before} from 'node:test'
import assert from 'node:assert/strict'
import {spawn} from 'node:child_process'
import {fileURLToPath} from 'node:url'
import {captureFluidSound} from '../soundfont.mjs'
import {openFluidStream} from '../soundfont-stream.mjs'
import {openPcmOutput} from '../pcm-output.mjs'
import {openMidiInput} from '../midi-input.mjs'
import {openMonitorSession} from '../step-monitor-session.mjs'
import {openStepInput} from '../step-input.mjs'
import {newEditor,editorCommand} from '../sequencer-editor.mjs'
import {phraseBacking} from '../phrase-backing.mjs'
let sound
before(async()=>{sound=await captureFluidSound().promise})
const fixture=name=>fileURLToPath(new URL(`./fixtures/${name}.mjs`,import.meta.url))

test('real FluidSynth plus owned MIDI/device children inserts one chord or preserves practice draft',async()=>{
  for(const practice of [false,true]) {
    let editor=editorCommand(newEditor(),'program 33').editor
    editor={...editor,project:{...editor.project,sound}}
    const original=structuredClone(editor), children=[],messages=[]
    const spawned=(...args)=>{const child=spawn(...args);children.push(child);return child}
    let sent=0,resolveSent
    const sounded=new Promise(resolve=>{resolveSent=resolve})
    const owner=openStepInput({source:'10',practice,
      audio:{sound,output:'owned',...(practice?{backing:phraseBacking(editor.project,'track-1')}: {})},
      getEditor:()=>editor,adoptEditor(next){editor=next},enqueue:action=>Promise.resolve().then(action),
      openInput:options=>openMidiInput({...options,spawnProcess(_command,args,config){return spawned(process.execPath,[fixture('midi-input-owner'),'step-chord',...args],config)}}),
      openMonitor:options=>{
        const monitor=openMonitorSession({...options,
          openOutput:output=>openPcmOutput({...output,spawnProcess(_command,args,config){return spawned(process.execPath,[fixture('pcm-output'),'fluid',...args],config)}}),
          openSynth:(selected,config)=>{const synth=openFluidStream(selected,{...config,spawnProcess:spawned});return {...synth,render(frames,rows){messages.push(...structuredClone(rows));return synth.render(frames,rows)}}},
        })
        return {...monitor,async send(value){await monitor.send(value);if(++sent===3)resolveSent()}}
      },
    })
    try {
      await owner.ready
      await sounded
      owner.stop();await owner.completion
      assert.ok(children.every(c=>c.exitCode!==null||c.signalCode!==null))
      for(const c of children)assert.throws(()=>process.kill(c.pid,0),{code:'ESRCH'})
      assert.deepEqual(messages.slice(0,3).map(x=>x.bytes),[[0xc0,33],[0xb0,7,100],[0xb0,10,64]])
      if(practice)assert.deepEqual(editor,original)
      else {
        assert.deepEqual(editor.project.tracks[0].notes.map(n=>[n.pitch,n.velocity,n.start]),[[60,72,0],[64,127,0]])
        assert.equal(editor.tick,960)
        assert.equal(editorCommand(editor,'undo').editor.project.tracks[0].notes.length,0)
      }
    }finally{owner.cancel();await owner.completion.catch(()=>{})}
  }
})
