// A `host --serve` stand-in: one process, NDJSON jobs answered by id.
// echo replies with this process id; hold waits for its cancel; stubborn
// never replies, like a plug-in load that cannot stop; crash exits.
if (process.argv.at(-1) !== '--serve') process.exit(2)
const reply = value => process.stdout.write(JSON.stringify(value) + '\n')
const held = new Set()
let text = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  text += chunk
  let end
  while ((end = text.indexOf('\n')) >= 0) {
    const request = JSON.parse(text.slice(0, end))
    text = text.slice(end + 1)
    if (request.cancel !== undefined) {
      if (held.delete(request.cancel)) reply({ id: request.cancel, ok: false, cancelled: true })
      continue
    }
    switch (request.job.operation) {
      case 'echo': reply({ id: request.id, ok: true, result: { value: request.job.value, pid: process.pid } }); break
      case 'hold': held.add(request.id); break
      case 'stubborn': break
      case 'fail': reply({ id: request.id, ok: false, error: 'SilentRender: selected VST produced silence' }); break
      case 'crash': process.stderr.write('native loader died\n'); process.exit(139)
    }
  }
})
process.stdin.on('end', () => process.exit(0))
