import { EditorState } from '@codemirror/state'
import { EditorView, lineNumbers } from '@codemirror/view'
import { lspExtension } from '../src/components/ide/ide-lsp-client'
const hints = [
  {position:{line:0,character:18},label:'right:',tooltip:'second argument'},
  {position:{line:0,character:9},label:[{value:': '},{value:'int',tooltip:{kind:'markdown',value:'**integer**'}}],tooltip:{kind:'plaintext',value:'inferred type'}},
  {position:{line:0,character:16},label:'left:',tooltip:'first argument'},
  {position:{line:0,character:9},label:' (inferred)'},
  {position:{line:1,character:999},label:'A'},
  {position:{line:1,character:998},label:'B'},
]
const messages: string[] = []
class FixtureSocket {
  static CONNECTING=0; static OPEN=1; static CLOSING=2; static CLOSED=3
  readyState=0
  onopen: (()=>void)|null=null
  onmessage: ((event:{data:string})=>void)|null=null
  onclose: (()=>void)|null=null
  constructor(_url:string){queueMicrotask(()=>{this.readyState=1;this.onopen?.()})}
  receive(value:unknown){queueMicrotask(()=>this.onmessage?.({data:JSON.stringify(value)}))}
  close(){this.readyState=3}
  send(raw:string){
    const msg=JSON.parse(raw); messages.push(msg.method)
    if(msg.method==='initialize') this.receive({id:msg.id,result:{masc:{workspaceRoot:'/workspace/masc'}}})
    else if(msg.method==='initialized') this.receive({method:'masc/lspStatus',params:{langs:[{lang:'ocaml',connected:true,command:'synthetic-fixture',last_error:null}]}})
    else if(msg.id) this.receive({id:msg.id,result:msg.method==='textDocument/inlayHint'?hints:msg.method==='textDocument/diagnostic'?{kind:'full',items:[]}:[]})
  }
}
Object.assign(window,{WebSocket:FixtureSocket})
const view=new EditorView({parent:document.querySelector('#editor')!,state:EditorState.create({
  doc:'let total = sum 3 7\nlet answer = total + 1',
  extensions:[lineNumbers(),lspExtension({filePath:'example.ml'}),EditorView.theme({'&':{backgroundColor:'#172130',color:'#e3eaf5'},'.cm-content':{padding:'24px 0'},'.cm-gutters':{backgroundColor:'#172130',color:'#8294ae'}})]
})})
Object.assign(window,{inlaySnapshot:()=>({messages,document:view.state.doc.toString(),hints:[...view.dom.querySelectorAll('.cm-inlayHint')].map(el=>({label:el.textContent,position:view.posAtDOM(el),tooltip:el.getAttribute('title'),parts:[...el.children].map(part=>({value:part.textContent,tooltip:part.getAttribute('title')}))}))})})
