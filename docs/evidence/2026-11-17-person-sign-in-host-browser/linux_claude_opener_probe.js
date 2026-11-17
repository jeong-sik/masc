// Does `claude auth login` on Linux start a URL opener, with and without BROWSER?
// No browser exists in the container. Recorders named after the usual openers sit
// first in PATH. Prints shapes only: no query values of the authorize link.
const fs = require('fs'), os = require('os'), path = require('path'), { spawn, execFileSync } = require('child_process')
const OPENERS = ['xdg-open', 'open', 'sensible-browser', 'x-www-browser', 'www-browser', 'gnome-open', 'kde-open', 'wslview', 'gio', 'firefox', 'google-chrome', 'chromium']
const recorder = (dir, name, log) => {
  const file = path.join(dir, name)
  fs.writeFileSync(file, `#!/bin/sh\nprintf '%s\\n' "$0" "$#" "$1" >> '${log}'\n`, { mode: 0o755 })
  return file
}
const shape = (log) => {
  if (!fs.existsSync(log)) return 'not started'
  const [name, argc, link] = fs.readFileSync(log, 'utf8').split('\n')
  let host = '?', redirect = '?'
  try { const u = new URL(link); host = u.host; redirect = u.searchParams.get('redirect_uri') || '(none)' } catch (_) { host = '(operand is no link)' }
  return `started ${path.basename(name)}: argc ${argc}, link host ${host}, redirect_uri ${redirect}`
}
const run = (label, browser) => new Promise((done) => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'opener-'))
  const shadow = path.join(work, 'shadow'); fs.mkdirSync(shadow)
  const openLog = path.join(work, 'open.log'), handlerLog = path.join(work, 'handler.log')
  for (const name of OPENERS) recorder(shadow, name, openLog)
  const handler = recorder(work, 'handler.sh', handlerLog)
  const config = path.join(work, 'claude-config'); fs.mkdirSync(config, { mode: 0o700 })
  const env = { HOME: process.env.HOME, USER: 'node', PATH: shadow + ':' + process.env.PATH, TMPDIR: os.tmpdir(), LANG: 'C.UTF-8', TERM: 'dumb',
    CLAUDE_CONFIG_DIR: config, ANTHROPIC_CONFIG_DIR: path.join(config, 'anthropic'), CLAUDE_CODE_ENTRYPOINT: 'masc',
    CLAUDE_AGENT_SDK_VERSION: 'masc-ocaml', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1', ENABLE_TOOL_SEARCH: 'true' }
  if (process.env.PROBE_DISPLAY) env.DISPLAY = process.env.PROBE_DISPLAY
  if (browser === 'handler') env.BROWSER = handler
  else if (browser !== null) env.BROWSER = browser
  const child = spawn('claude', ['auth', 'login'], { env, cwd: config, stdio: ['pipe', 'pipe', 'pipe'] })
  let text = ''
  child.stdout.on('data', (d) => { text += d }); child.stderr.on('data', (d) => { text += d })
  let exited = null
  child.on('exit', (code) => { exited = code })
  setTimeout(() => {
    const waiting = exited === null
    child.kill('SIGKILL')
    console.log(`[${label}] BROWSER=${browser === null ? '(unset)' : browser === 'handler' ? '<recorder>' : browser}`)
    console.log(`    opener on PATH   : ${shape(openLog)}`)
    console.log(`    BROWSER recorder : ${shape(handlerLog)}`)
    console.log(`    still waiting: ${waiting}${waiting ? '' : ' (exit ' + exited + ')'}; prints a link: ${/https:\/\//.test(text)}; asks for a code: ${/Paste code/.test(text)}`)
    if (!/https:\/\//.test(text)) console.log('    output: ' + text.replace(/https?:\/\/\S+/g, '<link>').trim().split('\n').slice(0, 4).join(' | ').slice(0, 300))
    done()
  }, 10000)
})
;(async () => {
  console.log('claude:', execFileSync('claude', ['--version']).toString().trim(), '| kernel:', os.type(), os.arch())
  const idle = ['/usr/bin/true', '/bin/true'].find((p) => fs.existsSync(p))
  await run('default', null)
  await run('fix', idle)
  if (!process.env.PROBE_DISPLAY) await run('control', 'handler')
})()
