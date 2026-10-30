import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { mkdir, mkdtemp, readFile, writeFile, realpath, lstat } from 'node:fs/promises'
import { dirname, join, relative, resolve, sep, posix } from 'node:path'
import { build, version as esbuildVersion } from 'esbuild'
import { parse, serialize, html as htmlNames, defaultTreeAdapter as tree, type DefaultTreeAdapterMap } from 'parse5'
import * as css from 'css-tree'
import type { BuildOptions, Loader, Plugin } from 'esbuild'
import { collectSite } from './site.ts'

type Element = DefaultTreeAdapterMap['element']
type Node = DefaultTreeAdapterMap['node']
export type ProjectBuild = { kind: 'browser_modules'; entry_html: string }
  | { kind: 'package_script'; script: string; output_directory: string; entry_html: string }
export type ProjectRequest = {
  schema: 'masc.artifact_project.v1'; build: ProjectBuild; install_scripts: boolean;
  files: { path: string; content_base64: string }[];
}
export class ProjectError extends Error {
  readonly stage: 'input' | 'install' | 'build'
  readonly run_directory: string | null
  constructor(stage: 'input' | 'install' | 'build', message: string, run_directory: string | null = null) { super(message); this.stage = stage; this.run_directory = run_directory }
}
const digest = (bytes: Uint8Array | string) => createHash('sha256').update(bytes).digest('hex')
function object(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ProjectError('input', 'Expected an object')
  const record = value as Record<string, unknown>
  if (Object.keys(record).some(key => !keys.includes(key)) || keys.some(key => !(key in record))) throw new ProjectError('input', 'Unexpected or missing fields')
  return record
}
function path(value: unknown): string {
  if (typeof value !== 'string' || !value || value.includes('\\') || value.includes('\0')
    || value.split('/').some(part => !part || part === '.' || part === '..') || /^[a-zA-Z]:/.test(value)) {
    throw new ProjectError('input', 'Expected a relative project file path without traversal')
  }
  return value
}
export function decodeProject(value: unknown): ProjectRequest {
  const record = object(value, ['schema', 'build', 'install_scripts', 'files'])
  if (record.schema !== 'masc.artifact_project.v1' || typeof record.install_scripts !== 'boolean' || !Array.isArray(record.files)) throw new ProjectError('input', 'Invalid project contract')
  const files = record.files.map(value => {
    const file = object(value, ['path', 'content_base64']), name = path(file.path)
    if (name.split('/').some(part => part === 'node_modules' || part === '.git')) throw new ProjectError('input', 'Dependency and Git directories are not source uploads')
    if (typeof file.content_base64 !== 'string' || Buffer.from(file.content_base64, 'base64').toString('base64') !== file.content_base64) throw new ProjectError('input', 'Expected canonical base64 file bytes')
    return { path: name, content_base64: file.content_base64 }
  })
  if (new Set(files.map(file => file.path)).size !== files.length) throw new ProjectError('input', 'Duplicate project path')
  if (!files.some(file => file.path === 'package.json')) throw new ProjectError('input', 'Project must contain package.json')
  if (!record.build || typeof record.build !== 'object' || Array.isArray(record.build)) throw new ProjectError('input', 'Expected a build selection')
  const kind = (record.build as Record<string, unknown>).kind
  let selected: ProjectBuild
  if (kind === 'browser_modules') {
    const build = object(record.build, ['kind', 'entry_html'])
    const entry_html = path(build.entry_html)
    if (!files.some(file => file.path === entry_html)) throw new ProjectError('input', 'Project must contain entry HTML')
    selected = { kind, entry_html }
  } else if (kind === 'package_script') {
    const build = object(record.build, ['kind', 'script', 'output_directory', 'entry_html'])
    if (typeof build.script !== 'string' || !build.script || build.script.includes('\0')) throw new ProjectError('input', 'Expected an exact package script name')
    selected = { kind, script: build.script, output_directory: path(build.output_directory), entry_html: path(build.entry_html) }
  } else throw new ProjectError('input', 'Unknown build kind')
  return { schema: 'masc.artifact_project.v1', build: selected, install_scripts: record.install_scripts, files }

}

// The caller dispatches this process through its existing Keeper execution lane.
// This worker is not a sandbox. Even install hooks run only in that lane.
function runNpm(cwd: string, home: string, args: readonly string[], stage: 'install' | 'build'): Promise<void> {
  return new Promise((ok, fail) => {
    const child = spawn('npm', args, {
      cwd, stdio: ['ignore', 'pipe', 'pipe'],
      env: { PATH: process.env.PATH, HOME: home, TMPDIR: home, npm_config_cache: join(home, 'cache'),
        npm_config_userconfig: join(home, 'npmrc'), npm_config_globalconfig: join(home, 'global-npmrc'), CI: 'true' },
    })
    child.stdout.pipe(process.stderr, { end: false }); child.stderr.pipe(process.stderr, { end: false })
    child.once('error', error => fail(new ProjectError(stage, error.message)))
    child.once('close', (code, signal) => code === 0 ? ok() : fail(new ProjectError(stage, `npm exited with ${signal ?? code}`)))
  })
}
function elements(node: Node): Element[] {
  const result: Element[] = []
  const visit = (value: Node) => {
    if (tree.isElementNode(value)) result.push(value)
    if ('childNodes' in value) value.childNodes.forEach(visit)
    // Template contents remain inert; they are not separate executable entries.
  }
  visit(node); return result
}
const attr = (node: Element, name: string) => node.attrs.find(attribute => attribute.name === name)?.value
const remove = (node: Element) => tree.detachNode(node)
function append(parent: Element, name: string, text: string, attrs: Element['attrs'] = []) {
  const node = tree.createElement(name, htmlNames.NS.HTML, attrs)
  tree.insertText(node, text); tree.appendChild(parent, node)
}
const mime: Record<string, string> = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.otf': 'font/otf', '.mp3': 'audio/mpeg', '.mp4': 'video/mp4', '.avif': 'image/avif' }

export async function buildProject(input: unknown, workspace: string) {
  const request = decodeProject(input)
  const owner = await realpath(workspace)
  if (!(await lstat(owner)).isDirectory()) throw new ProjectError('input', 'Workspace is not a directory')
  const run = await mkdtemp(join(owner, 'artifact-project-'))
  try {
  await writeFile(join(run, 'request.json'), JSON.stringify(request) + '\n', { mode: 0o600, flag: 'wx' })
  const source = join(run, 'source'), home = join(run, 'npm-home')
  await mkdir(source, { mode: 0o700 }); await mkdir(home, { mode: 0o700 })
  for (const file of request.files) {
    const target = join(source, file.path)
    await mkdir(dirname(target), { recursive: true, mode: 0o700 })
    // wx also rejects aliases on a case-insensitive filesystem. Never overwrite.
    await writeFile(target, Buffer.from(file.content_base64, 'base64'), { flag: 'wx', mode: 0o600 })
  }
  const packageJSON = JSON.parse(await readFile(join(source, 'package.json'), 'utf8')) as unknown
  if (!packageJSON || typeof packageJSON !== 'object' || Array.isArray(packageJSON)) throw new ProjectError('input', 'Invalid package.json')
  if (request.build.kind === 'package_script') {
    const scripts = (packageJSON as Record<string, unknown>).scripts
    if (!scripts || typeof scripts !== 'object' || Array.isArray(scripts) || !Object.hasOwn(scripts, request.build.script)
      || typeof (scripts as Record<string, unknown>)[request.build.script] !== 'string') throw new ProjectError('input', 'Requested script is not defined in package.json')
  }
  const locked = request.files.some(file => file.path === 'package-lock.json' || file.path === 'npm-shrinkwrap.json')
  const lockPath = request.files.some(file => file.path === 'npm-shrinkwrap.json') ? 'npm-shrinkwrap.json' : 'package-lock.json'
  if (!locked) await runNpm(source, home, ['install', '--package-lock-only', '--ignore-scripts', '--include=dev', '--no-audit', '--no-fund'], 'install')
  // Freeze the exact lock before installation hooks or build scripts can change
  // it. npm ci validates and resolves this lock before its preinstall hooks.
  const lock = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await readFile(join(source, lockPath)))
  await runNpm(source, home, ['ci', '--include=dev', '--no-audit', '--no-fund', `--ignore-scripts=${!request.install_scripts}`], 'install')
  const finish = async <B, O>(build: B, output: O) => {
    const result = {
      schema: 'masc.artifact_project_result.v1', runtime: { node: process.version, platform: process.platform, arch: process.arch }, run_directory: run,
      source_files: request.files.map(file => ({ path: file.path, sha256: digest(Buffer.from(file.content_base64, 'base64')) })),
      install: { mode: 'ci' as const, lock_source: locked ? 'supplied' as const : 'resolved' as const, scripts: request.install_scripts, lockfile: lockPath, lock_sha256: digest(lock), lock_content: lock },
      build, output,
    }
    await writeFile(join(run, 'result.json'), JSON.stringify(result) + '\n', { mode: 0o600, flag: 'wx' })
    return result
  }
  if (request.build.kind === 'package_script') {
    await runNpm(source, home, ['run', '--', request.build.script], 'build')
    const site = await collectSite(source, request.build.output_directory, request.build.entry_html)
    return await finish({ ...request.build }, site)
  }
  // No source is executed in the Dashboard/server process. Compile in the same
  // lane as npm, resolve only that installed project and retain all run files.
  const entry = join(source, request.build.entry_html)
  const page = parse(await readFile(entry, 'utf8'))
  const nodes = elements(page), body = nodes.find(node => node.tagName === 'body')!, head = nodes.find(node => node.tagName === 'head')!
  const imports: string[] = [], modules = new Map<string, { code: string; directory: string }>()
  const externalResources = new Set<string>()
  async function local(url: string): Promise<string | null> {
    const base = new URL('https://artifact.invalid/' + request.build.entry_html.split('/').map(encodeURIComponent).join('/'))
    const resolved = new URL(url, base)
    if (resolved.origin !== base.origin || resolved.protocol !== 'https:') {
      if (resolved.protocol === 'https:' || resolved.protocol === 'http:') externalResources.add(url)
      return null
    }
    const name = decodeURIComponent(resolved.pathname.slice(1))
    const target = resolve(source, name), actual = await realpath(target), rel = relative(source, actual)
    if (!rel || rel === '..' || rel.startsWith('..' + sep) || resolve(actual) !== target || !(await lstat(actual)).isFile()) throw new ProjectError('build', `Resource is not a regular project file: ${url}`)
    if (resolved.search) throw new ProjectError('build', `Resource query needs a framework build: ${url}`)
    return actual
  }
  const fileLoaders: Record<string, Loader> = { '.js': 'js', '.mjs': 'js', '.cjs': 'js', '.jsx': 'jsx', '.ts': 'ts', '.mts': 'ts', '.cts': 'ts', '.tsx': 'tsx', '.css': 'css', '.json': 'json',
    ...Object.fromEntries(Object.keys(mime).map(extension => [extension, 'dataurl' as const])) }
  const confinement: Plugin = { name: 'artifact-project-files', setup(builder) {
    builder.onLoad({ filter: /.*/, namespace: 'file' }, async args => {
      const actual = await realpath(args.path), rel = relative(source, actual)
      if (!rel || rel === '..' || rel.startsWith('..' + sep) || !(await lstat(actual)).isFile()) throw new ProjectError('build', `Import is outside the installed project: ${args.path}`)
      return { contents: await readFile(actual), loader: fileLoaders[posix.extname(actual)] ?? 'js', resolveDir: dirname(actual) }
    })
  } }
  const options: BuildOptions = { absWorkingDir: source, bundle: true, write: false, metafile: true, platform: 'browser',
    logLevel: 'silent', loader: Object.fromEntries(Object.keys(mime).map(extension => [extension, 'dataurl' as const])) }
  const warnings: string[] = [], inputs = new Set<string>()
  const record = (output: Awaited<ReturnType<typeof build>>) => {
    output.warnings.forEach(warning => warnings.push(warning.text))
    Object.keys(output.metafile?.inputs ?? {}).forEach(name => inputs.add(name))
  }
  async function stylesheet(contents: string, directory: string): Promise<string> {
    const output = await build({ ...options, stdin: { contents, resolveDir: directory, loader: 'css' }, outfile: join(run, 'bundle', 'style.css'), plugins: [confinement] })
    record(output)
    if (output.outputFiles?.length !== 1 || !output.outputFiles[0].path.endsWith('.css')) throw new ProjectError('build', 'Unembedded stylesheet output')
    return output.outputFiles[0].text.replace(/<\/style/gi, '<\\/style')
  }
  async function asset(url: string): Promise<string> {
    const target = await local(url)
    if (!target) return url
    const contentType = mime[posix.extname(target).toLowerCase()]
    if (!contentType) throw new ProjectError('build', `Unsupported HTML asset type: ${url}`)
    const hash = url.indexOf('#')
    const fragment = hash >= 0 ? url.slice(hash) : ''
    return `data:${contentType};base64,${(await readFile(target)).toString('base64')}${fragment}`
  }
  let moduleEntrySeen = false
  const moduleTypes = new Set(['module'])
  const classicTypes = new Set(['', 'text/javascript', 'application/javascript'])
  for (const node of nodes) {
    if (node.tagName === 'script') {
      const type = (attr(node, 'type') ?? '').trim().toLowerCase(), src = attr(node, 'src')
      if (type === 'importmap') throw new ProjectError('build', 'Import maps require a framework build')
      if (moduleTypes.has(type)) {
        if (moduleEntrySeen) throw new ProjectError('build', 'Multiple HTML module entries require a framework build')
        moduleEntrySeen = true
        const target = src === undefined ? null : await local(src)
        if (node.attrs.some(attribute => !['src', 'type', 'crossorigin'].includes(attribute.name))) throw new ProjectError('build', 'Module script attributes require a framework build')
        if (src !== undefined) imports.push(`import ${JSON.stringify(target ?? src)};`)
        else {
          const name = `artifact-inline:${modules.size}`
          modules.set(name, { code: tree.getTextNodeContent(node.childNodes.find(tree.isTextNode) ?? tree.createTextNode('')), directory: dirname(entry) })
          imports.push(`import ${JSON.stringify(name)};`)
        }
        remove(node)
      } else if (classicTypes.has(type) && src !== undefined) {
        const target = await local(src)
        if (target) {
          if (attr(node, 'async') !== undefined || attr(node, 'defer') !== undefined) throw new ProjectError('build', 'Classic async/defer scripts require a framework build')
          node.attrs = node.attrs.filter(attribute => attribute.name !== 'src' && attribute.name !== 'integrity' && attribute.name !== 'crossorigin')
          tree.insertText(node, (await readFile(target, 'utf8')).replace(/<\/script/gi, '<\\/script'))
        }
      }
    } else if (node.tagName === 'link' && (attr(node, 'rel') ?? '').toLowerCase().split(/\s+/).includes('stylesheet')) {
      const href = attr(node, 'href')
      if (href) {
        const target = await local(href)
        if (target) {
          if (node.attrs.some(attribute => !['rel', 'href', 'media'].includes(attribute.name))) throw new ProjectError('build', 'Stylesheet attributes require a framework build')
          const replacement = tree.createElement('style', htmlNames.NS.HTML, node.attrs.filter(attribute => attribute.name === 'media'))
          tree.insertText(replacement, await stylesheet(await readFile(target, 'utf8'), dirname(target)))
          tree.insertBefore(node.parentNode!, replacement, node); remove(node)
        }
      }
    } else if (node.tagName === 'style') {
      const value = node.childNodes.filter(tree.isTextNode).map(tree.getTextNodeContent).join('')
      const converted = await stylesheet(value, dirname(entry))
      node.childNodes.forEach(child => { child.parentNode = null }); node.childNodes = []
      tree.insertText(node, converted)
    } else if (node.tagName === 'base') throw new ProjectError('build', 'A base URL requires a framework build')
    if (attr(node, 'srcset') !== undefined) throw new ProjectError('build', 'srcset requires a framework build')
    for (const attribute of node.attrs) {
      if (attribute.name === 'style') {
        const ast = css.parse(attribute.value, { context: 'declarationList', parseCustomProperty: true, onParseError(error) { throw error } })
        const urls: css.Url[] = []
        css.walk(ast, value => { if (value.type === 'Url') urls.push(value) })
        for (const value of urls) value.value = await asset(value.value)
        attribute.value = css.generate(ast)
      } else if ((attribute.name === 'src' && node.tagName !== 'script') || attribute.name === 'poster' || (attribute.name === 'href' && node.tagName === 'link' && !(attr(node, 'rel') ?? '').toLowerCase().split(/\s+/).includes('stylesheet'))) {
        attribute.value = await asset(attribute.value)
      }
    }
  }
  const output = await build({
    ...options, stdin: { contents: imports.join('\n'), resolveDir: dirname(entry), sourcefile: 'artifact-entry.js' },
    outfile: join(run, 'bundle', 'app.js'), format: 'esm', jsx: 'automatic',
    define: { 'process.env.NODE_ENV': '"production"' }, logLevel: 'silent',
    loader: Object.fromEntries(Object.keys(mime).map(extension => [extension, 'dataurl' as const])),
    plugins: [confinement, { name: 'artifact-inline', setup(builder) {
      builder.onResolve({ filter: /^artifact-inline:/ }, args => ({ path: args.path, namespace: 'artifact-inline' }))
      builder.onLoad({ filter: /.*/, namespace: 'artifact-inline' }, args => {
        const value = modules.get(args.path)!
        return { contents: value.code, resolveDir: value.directory, loader: 'js' }
      })
    } }],
  })
  record(output)
  for (const file of output.outputFiles ?? []) {
    if (file.path.endsWith('.js')) append(body, 'script', file.text.replace(/<\/script/gi, '<\\/script'), [{name:'type',value:'module'}])
    else if (file.path.endsWith('.css')) append(head, 'style', file.text.replace(/<\/style/gi, '<\\/style'))
    else throw new ProjectError('build', `Unembedded build output: ${file.path}`)
  }
  const html = serialize(page)
  return await finish({ kind: 'browser_modules' as const, entry_html: request.build.entry_html, esbuild: esbuildVersion, inputs: [...inputs], warnings, external_resources: [...externalResources] },
    { kind: 'html' as const, artifact: { format: 'html' as const, content: html, sha256: digest(html) } })
  } catch (error) {
    const failure = new ProjectError(error instanceof ProjectError ? error.stage : 'build', error instanceof Error ? error.message : String(error), run)
    try { await writeFile(join(run, 'failure.json'), JSON.stringify({ stage: failure.stage, message: failure.message }) + '\n', { mode: 0o600, flag: 'wx' }) }
    catch (recordError) { throw new ProjectError(failure.stage, `${failure.message}; failed to store failure record: ${recordError instanceof Error ? recordError.message : String(recordError)}`, run) }
    throw failure
  }
}
