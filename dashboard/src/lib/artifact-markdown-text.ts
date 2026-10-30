import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { toHast } from 'mdast-util-to-hast'
import { raw } from 'hast-util-raw'
import { toHtml } from 'hast-util-to-html'
import { parse } from 'parse5'
import type { Text } from 'mdast'
import type { Element, ElementContent } from 'hast'
import { artifactTextFrame, type ArtifactTextEditor, type ArtifactTextPart } from './artifact-text-frame'

export function artifactMarkdownTextEditor(source:string):ArtifactTextEditor {
  const token=crypto.randomUUID(),binding=`data-masc-binding-${token}`
  const parts:ArtifactTextPart[]=[]
  // Micromark consumes one leading BOM before calculating its offsets. Keep
  // that original code unit in the source and translate positions back to it.
  const sourceOrigin=source.charCodeAt(0)===0xFEFF?1:0
  const markdown=fromMarkdown(source,{extensions:[gfm()],mdastExtensions:[gfmFromMarkdown()]})
  const hast=toHast(markdown,{allowDangerousHtml:true,footnoteLabel:'각주',handlers:{text(_state,node:Text):Element {
    const start=node.position?.start.offset,end=node.position?.end.offset
    if(start===undefined||end===undefined)throw new Error('Markdown 원문 위치를 확인하지 못했습니다.')
    const id=parts.length,originalStart=start+sourceOrigin,originalEnd=end+sourceOrigin
    parts.push({id,start:originalStart,end:originalEnd,raw:source.slice(originalStart,originalEnd),text:node.value})
    const children:ElementContent[]=[]
    node.value.replaceAll('\r\n','\n').replaceAll('\r','\n').split('\n').forEach((value,index)=>{
      if(index)children.push({type:'element',tagName:'br',properties:{},children:[]})
      children.push({type:'text',value})
    })
    return {type:'element',tagName:'span',properties:{[binding]:String(id)},children}
  }}})
  // Parse embedded HTML before the shared frame removes active content and
  // recognizes only the wrappers created by this render's capability.
  return artifactTextFrame(parse(toHtml(raw(hast))),token,parts,binding)
}
