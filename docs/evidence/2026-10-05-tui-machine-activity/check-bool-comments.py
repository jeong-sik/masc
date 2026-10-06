import hashlib,json,os,subprocess,tempfile,sys
from pathlib import Path
root=Path(sys.argv[1]); label=sys.argv[2]; old=sys.argv[3] if len(sys.argv)>3 else None
work=Path(tempfile.mkdtemp(prefix='masc-bool-comment-'+label+'-'))
bin=Path(os.environ['ACTIVITY_OCAML_BIN']); env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ.get('PATH',''))
sources={}; log=[]; cmds=[]; exit_code=0
for source in ['lib/toml_line_editor/toml_line_editor.mli','lib/toml_line_editor/toml_line_editor.ml','test/toml_line_editor/test_toml_line_editor.ml']:
    content=subprocess.check_output(['git','show',old+':'+source],cwd=root) if old and source.startswith('lib/') else (root/source).read_bytes()
    (work/Path(source).name).write_bytes(content); sources[source]=hashlib.sha256(content).hexdigest()
compiler=[str(bin/'ocamlfind'),'ocamlc','-w','+32+69','-warn-error','+a','-package','otoml,alcotest']
commands=[[str(bin/'ocamlc'),'-version']]+[compiler+['-c',p] for p in ['toml_line_editor.mli','toml_line_editor.ml','test_toml_line_editor.ml']]+[compiler+['-linkpkg','toml_line_editor.cmo','test_toml_line_editor.cmo','-o','test.exe'],[str(work/'test.exe'),'--color=never']]
for cmd in commands:
    result=subprocess.run(cmd,cwd=work,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    cmds.append({'argv':cmd,'exit_code':result.returncode}); log.append('$ '+' '.join(cmd)+'\n'+result.stdout.rstrip()+'\n')
    if result.returncode: exit_code=result.returncode; break
Path('/tmp/masc-bool-comment-'+label+'.txt').write_text('\n'.join(log))
Path('/tmp/masc-bool-comment-'+label+'.json').write_text(json.dumps({'scope':'Actual full Toml_line_editor module/interface and existing direct test file; no extracted modules or behavioral mocks','old_product_head':old,'temporary_directory':str(work),'sources':sources,'commands':cmds},indent=2)+'\n')
print('exit',exit_code,'log /tmp/masc-bool-comment-'+label+'.txt')
print(log[-1][-4200:])
sys.exit(exit_code)
