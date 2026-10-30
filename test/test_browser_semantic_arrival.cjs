"use strict";
// Execute the product resolver against observed rectangles and hit-test results.
// Native Chromium integration is covered by stagehand_browser_probe.ml.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname,"../lib/browser_interaction.ml"),"utf8");
const script = source.split("let pointer_target_script = {js|",2)[1].split("|js}",1)[0];
function resolve({rect={left:400,right:600,top:100,bottom:200},covered=false,onlyCenter=false}={}) {
  const element = box => ({isConnected:true,localName:"div",parentElement:null,
    getRootNode:()=>({host:null}),getClientRects:()=>[box]});
  const from=element({left:100,right:200,top:100,bottom:200}), to=element(rect), cover=element(rect);
  const cx=Math.floor((Math.max(0,rect.left)+Math.min(800,rect.right))/2);
  const cy=Math.floor((Math.max(0,rect.top)+Math.min(600,rect.bottom))/2);
  const context={innerWidth:800,innerHeight:600,location:{href:"https://example.org/fixture"},
    getComputedStyle:()=>({display:"block",visibility:"visible",opacity:"1"}),
    browserScene:()=>({documentId:"d1",width:800,height:600,scrollX:0,scrollY:0}),
    document:{querySelectorAll:selector=>selector==="#source"?[from]:[to],
      elementFromPoint(x,y) {
        if(x>=100&&x<200&&y>=100&&y<200)return from;
        if(x>=rect.left&&x<rect.right&&y>=rect.top&&y<rect.bottom)
          return covered||(onlyCenter&&(x!==cx||y!==cy))?cover:to;
        return null;
      }},args:{action:"drag_to",expectedUrl:"https://example.org/fixture",
        source:{selector:"#source"},destination:{selector:"#destination"}}};
  return JSON.parse(JSON.stringify(vm.runInNewContext(`(function(){${script}})(args)`,context)));
}
const normal=resolve();
assert.deepEqual(normal.to,{x:500/800,y:150/600});
assert.deepEqual(normal.arrival,{x:450/800,y:150/600});
assert.notDeepEqual(normal.arrival,normal.to);
assert.equal(resolve({onlyCenter:true}).arrival,undefined,"occluded arrival points are omitted");
assert.deepEqual(resolve({covered:true}).interactionFailure,
  {message:"element_pointer_obstructed",effectStarted:false},"covered center refuses before input");
const clipped=resolve({rect:{left:-40,right:20,top:300,bottom:400}});
assert.deepEqual(clipped.arrival,{x:5/800,y:350/600},"arrival derives from the viewport-clipped destination");
assert.equal(resolve({rect:{left:400,right:401,top:100,bottom:101}}).arrival,undefined,
  "a destination without a distinct hit-tested pixel does not invent one");
console.log("semantic drag arrival geometry and obstruction checks PASS");
