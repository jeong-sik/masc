import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, mkdir, copyFile, symlink, rename, rm } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

// Exercise copied runtime modules, rather than a checkout import or a text
// assertion that a particular filename appears in the installer.
test('declared installed music bundle loads its real editors and cannot borrow missing local modules from the checkout', async () => {
  const source = fileURLToPath(new URL('../', import.meta.url))
  const installer = await readFile(new URL('../../../scripts/install-alphatex.sh', import.meta.url), 'utf8')
  const manifest = /^runtime_files='([^']+)'$/m.exec(installer)
  assert.ok(manifest, 'Installer must declare its runtime files')
  const root = await mkdtemp(join(tmpdir(), 'masc-installed-music-'))
  const run = () => spawnSync(process.execPath, ['--input-type=module', '--eval', `
    import assert from 'node:assert/strict';
    import {pathToFileURL} from 'node:url';
    import {join} from 'node:path';
    const root=process.argv[1];
    for(const name of ['sequencer-tui.mjs','arrangement-tui.mjs','music-workbench.mjs'])
      await import(pathToFileURL(join(root,name)));
    const {newEditor,editorCommand}=await import(pathToFileURL(join(root,'sequencer-editor.mjs')));
    let editor=newEditor();
    for(const line of ['note C4 8.3 1/3 91','select-all','quantize-notes 1/3'])
      editor=editorCommand(editor,line).editor;
    assert.deepEqual(editor.project.tracks[0].notes.map(n=>[n.start,n.duration,n.velocity]),[[8000,320,91]]);
  `, root], { cwd: root, encoding: 'utf8' })
  try {
    for (const file of manifest[1].split(/\s+/)) {
      const target = join(root,file)
      await mkdir(dirname(target),{recursive:true})
      await copyFile(join(source,file),target)
    }
    // Only third-party dependencies are shared. Every relative application
    // module must resolve inside the copied runtime in a fresh Node process.
    await symlink(join(source,'node_modules'),join(root,'node_modules'),process.platform === 'win32' ? 'junction' : 'dir')
    const complete = run()
    assert.equal(complete.status,0,complete.stderr)
    for (const file of ['tick-units.mjs','note-quantize.mjs','note-overlap.mjs']) {
      await rename(join(root,file),join(root,file+'.absent'))
      const missing = run()
      assert.notEqual(missing.status,0)
      assert.match(missing.stderr,/ERR_MODULE_NOT_FOUND/)
      assert.ok(missing.stderr.includes(file),missing.stderr)
      await rename(join(root,file+'.absent'),join(root,file))
    }
  } finally { await rm(root,{recursive:true,force:true}) }
})
