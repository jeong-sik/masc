"use strict";
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,'../lib/browser_interaction.ml'),'utf8');
const body = source.split('let keyboard_guard_script = {js|',2)[1].split('|js}',1)[0];
function guard({url='https://example.org',documentId='d1',action='type_text',focus={}}={}) {
  const focused = {isConnected:true,localName:'input',type:'text',parentElement:null,
    getAttribute:()=>null,matches:()=>false,...focus};
  let mutations=0;
  focused.focus=()=>{mutations++;throw Error('guard must never focus')};
  focused.dispatchEvent=()=>{mutations++;throw Error('guard must never dispatch')};
  const context={args:{expectedUrl:url,documentId,action},location:{href:'https://example.org'},
    browserScene:()=>({documentId:'d1'}),document:{activeElement:focused},
    documentId:'d1',scrollX:0,scrollY:0};
  const result=()=>vm.runInNewContext(`(function(){${body}})(args)`,context);
  return {result,mutations:()=>mutations};
}
let check=guard();assert.equal(check.result().url,'https://example.org');assert.equal(check.mutations(),0);
assert.throws(guard({url:'https://stale.example'}).result,/page_url_changed/);
assert.throws(guard({documentId:'stale'}).result,/scene_document_changed/);
assert.throws(guard({focus:{disabled:true}}).result,/keyboard_focus_disabled/);
assert.throws(guard({focus:{parentElement:{inert:true}}}).result,/keyboard_focus_disabled/);
assert.throws(guard({focus:{readOnly:true}}).result,/keyboard_focus_not_editable/);
assert.throws(guard({focus:{localName:'input',type:'checkbox'}}).result,/keyboard_focus_not_editable/);
assert.throws(guard({focus:{localName:'body'}}).result,/keyboard_focus_not_editable/);
assert.doesNotThrow(guard({action:'press_key',focus:{localName:'body'}}).result);
assert.doesNotThrow(guard({focus:{localName:'textarea'}}).result);
assert.doesNotThrow(guard({focus:{localName:'div',isContentEditable:true}}).result);
assert.doesNotThrow(guard({focus:{localName:'custom-editor',shadowRoot:{activeElement:{isConnected:true,
  localName:'textarea',parentElement:null,getAttribute:()=>null,matches:()=>false}}}}).result);
for(const host of [{inert:true,getAttribute:()=>null},{getAttribute:key=>key==='aria-disabled'?'true':null}])
  assert.throws(guard({focus:{shadowRoot:{activeElement:{isConnected:true,localName:'textarea',
    parentElement:null,getRootNode:()=>({host}),getAttribute:()=>null,matches:()=>false}}}}).result,/keyboard_focus_disabled/);
console.log('actual keyboard document/focus guards PASS');
