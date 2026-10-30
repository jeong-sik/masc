import { defaultTreeAdapter as tree, html, serialize, serializeOuter, type DefaultTreeAdapterTypes as Nodes } from 'parse5'

export type ArtifactTextPart = { id: number; start: number; end: number; raw: string; text: string }
export type ArtifactTextEditor = { document: string; token: string; parts: readonly ArtifactTextPart[] }
export const artifactFrameRemovedTags: ReadonlySet<string> = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'base', 'meta', 'link'])
const marker = 'data-masc-artifact-text'
const controls = new Set(['input', 'textarea', 'select', 'button'])

// Only wrappers bearing this render's random binding attribute are editable.
// Source HTML never receives the parent's credentials or navigation authority.
export function artifactTextFrame(document: Nodes.Document, token: string, parts: readonly ArtifactTextPart[], binding: string): ArtifactTextEditor {
  function visit(parent: Nodes.ParentNode): void {
    for(const node of [...parent.childNodes]) {
      if(!tree.isElementNode(node))continue
      if(artifactFrameRemovedTags.has(node.tagName)){tree.detachNode(node);continue}
      const bound=node.attrs.find(attr=>attr.name===binding)?.value
      node.attrs=node.attrs.filter(attr=>![binding,marker,'nonce','contenteditable','autofocus','href','action','formaction','target'].includes(attr.name))
      if(bound!==undefined && node.namespaceURI===html.NS.HTML) {
        const id=Number(bound),part=Number.isSafeInteger(id)?parts[id]:undefined
        if(part)node.attrs.push({name:marker,value:String(id)},{name:'tabindex',value:'0'},{name:'role',value:'button'},{name:'aria-label',value:`문장 편집: ${part.text}`})
      }
      if(controls.has(node.tagName))node.attrs.push({name:'disabled',value:''})
      visit(node)
      if(node.namespaceURI===html.NS.HTML && node.tagName==='template')visit(tree.getTemplateContent(node as Nodes.Template))
    }
  }
  visit(document)
  const root=document.childNodes.find(tree.isElementNode)!
  const head=root.childNodes.find(node=>tree.isElementNode(node)&&node.tagName==='head') as Nodes.Element
  let body=root.childNodes.find(node=>tree.isElementNode(node)&&node.tagName==='body') as Nodes.Element|undefined
  if(!body){body=tree.createElement('body',html.NS.HTML,[]);tree.appendChild(root,body)}
  const policy=tree.createElement('meta',html.NS.HTML,[{name:'http-equiv',value:'Content-Security-Policy'},
    {name:'content',value:`default-src 'none'; script-src 'nonce-${token}'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`}])
  const style=tree.createElement('style',html.NS.HTML,[])
  tree.insertText(style,`[${marker}]{cursor:text}[${marker}]:hover,[${marker}]:focus-visible{outline:2px solid #1684c9;outline-offset:2px}`);tree.appendChild(head,style)
  const script=tree.createElement('script',html.NS.HTML,[{name:'nonce',value:token}])
  tree.insertText(script,`(()=>{
    const nodes=new Map(Array.from(document.querySelectorAll('[${marker}]'),node=>[node,node.getAttribute('${marker}')]))
    const choose=event=>{
      event.preventDefault()
      const node=event.target instanceof Element?event.target.closest('[${marker}]'):null
      const id=node&&nodes.get(node)
      if(id!==undefined&&id!==null)window.parent.postMessage({type:'masc.artifact.text.selected.v1',token:${JSON.stringify(token)},id:Number(id)},'*')
    }
    document.addEventListener('click',choose,true)
    document.addEventListener('submit',event=>event.preventDefault(),true)
    document.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' ')choose(event)},true)
  })()`)
  tree.appendChild(body,script)
  return {document:'<!doctype html><meta charset="utf-8">'+serializeOuter(policy)+serialize(document),token,parts}
}

export function selectedArtifactText(editor: ArtifactTextEditor, message: unknown): ArtifactTextPart|null {
  if(typeof message!=='object'||message===null)return null
  const value=message as Record<string,unknown>
  if(value.type!=='masc.artifact.text.selected.v1'||value.token!==editor.token||typeof value.id!=='number'||!Number.isSafeInteger(value.id))return null
  return editor.parts[value.id]??null
}
