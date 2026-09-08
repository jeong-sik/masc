import { createHash } from 'node:crypto'
import { relative, resolve, sep } from 'node:path'
import ts from 'typescript'
import MagicString from 'magic-string'
import type { Plugin } from 'vite'

// TypeScript parses tagged templates and JSX; no HTML/selector guessing.
// HTM locations identify the template expression, not a fabricated tag line.
export function instrumentSource(code: string, id: string, projectRoot: string) {
  const file = relative(projectRoot, id).split(sep).join('/')
  if (file.startsWith('../') || file === '..') return undefined
  const source = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true,
    id.endsWith('.tsx') || id.endsWith('.jsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const htmlImports = new Set<ts.Identifier>()
  const names = new Set<string>()
  const bindings = new Map<string, ts.Identifier[]>()
  function collect(node: ts.Node) {
    if (ts.isIdentifier(node)) names.add(node.text)
    if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)
      && node.moduleSpecifier.text === 'htm/preact') {
      const imports = node.importClause?.namedBindings
      if (imports && ts.isNamedImports(imports)) for (const spec of imports.elements) {
        if ((spec.propertyName?.text ?? spec.name.text) === 'html') htmlImports.add(spec.name)
      }
    }
    // A shadowed html import is left untouched. This explicit unsupported case
    // cannot attach the wrong template implementation to a source location.
    if ((ts.isVariableDeclaration(node) || ts.isParameter(node) || ts.isBindingElement(node)
      || ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node)
      || ts.isFunctionExpression(node) || ts.isClassExpression(node))
      && node.name && ts.isIdentifier(node.name)) {
      const old = bindings.get(node.name.text) ?? []
      old.push(node.name); bindings.set(node.name.text, old)
    }
    ts.forEachChild(node, collect)
  }
  collect(source)
  const tags = new Set([...htmlImports].map(node => node.text).filter(name => !bindings.has(name)))
  let helper = '__mascSourceHtml'
  while (names.has(helper)) helper += '_'
  let hasTemplates = false
  const edits: {start: number; end: number; text: string}[] = []
  const digest = createHash('sha256').update(code).digest('hex')
  function metadata(node: ts.Node, kind: 'template' | 'element') {
    const point = source.getLineAndCharacterOfPosition(node.getStart(source))
    return JSON.stringify({schema:'masc.source.v1',file,line:point.line+1,
      column:point.character+1,kind,digest})
  }
  function visit(node: ts.Node) {
    if (ts.isTaggedTemplateExpression(node) && ts.isIdentifier(node.tag) && tags.has(node.tag.text)) {
      hasTemplates = true
      // A hoisted export may run through an ESM cycle before this module's
      // declarations initialize. Resolve its cached tag at the call site.
      edits.push({start:node.tag.getStart(source),end:node.tag.end,
        text:`${helper}(${JSON.stringify(metadata(node, 'template'))})`})
    }
    if ((ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node))
      && ts.isIdentifier(node.tagName)
      && ((node.tagName.text.charAt(0) >= 'a' && node.tagName.text.charAt(0) <= 'z') || node.tagName.text.includes('-'))
      && !node.attributes.properties.some(prop => ts.isJsxAttribute(prop) && prop.name.getText(source) === 'data-masc-source')) {
      edits.push({start:node.attributes.end,end:node.attributes.end,
        text:` data-masc-source={${JSON.stringify(metadata(node, 'element'))}}`})
    }
    ts.forEachChild(node, visit)
  }
  visit(source)
  if (!edits.length) return undefined
  const output = new MagicString(code)
  for (const edit of edits) {
    if (edit.start === edit.end) output.appendLeft(edit.start, edit.text)
    else output.overwrite(edit.start, edit.end, edit.text)
  }
  if (hasTemplates) output.prepend(`import { sourceHtml as ${helper} } from "/@masc/source-context-runtime";\n`)
  return {code:output.toString(), map:output.generateMap({hires:true,source:id,includeContent:true})}

}

export function sourceContextPlugin(): Plugin {
  let projectRoot = ''
  let runtime = ''
  return {
    name:'masc-browser-source-context', apply:'serve', enforce:'pre',
    configResolved(config) {
      projectRoot = resolve(config.root,'..')
      runtime = resolve(config.root,'dev/source-context-runtime.ts')
    },
    resolveId(id) {
      if (id === '/@masc/source-context-runtime') return runtime
      return undefined
    },
    transform(code,id) {
      const path = id.split('?')[0]
      if (!path || !['.ts','.tsx','.js','.jsx'].some(ext => path.endsWith(ext))
        || !path.startsWith(resolve(projectRoot,'dashboard/src')+sep)
        || path.endsWith('.test.ts') || path.endsWith('.test.tsx')) return undefined
      return instrumentSource(code,path,projectRoot)
    },
  }
}
