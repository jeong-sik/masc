from pathlib import Path
import hashlib,json,os,subprocess,sys,tempfile,time
from run_native import ROOT,REPO,WORK,PREVIOUS,digest

def main():
    root=ROOT/(sys.argv[1] if len(sys.argv)>1 else 'checks-r2')
    root.mkdir()
    native=ROOT/'native-r1'
    previous=json.loads(PREVIOUS.read_text())
    prefix=[previous[0]['argv'][0],'-I',str(root),'-I',str(native)]+previous[0]['argv'][3:-2]
    link=next(row['argv'] for row in previous if row['label']=='link')
    link=link[:link.index('-o')]
    suite=(WORK/'test/test_runtime_model_input_tail_window.ml').read_bytes()
    transformed=suite.replace(b'module Window = Runtime_model_input_tail_window',b'module Window = Window_under_test').replace(b'Keeper_official_client_context_codec.',b'Codec_under_test.')
    (root/'window_suite.ml').write_bytes(transformed)
    (root/'compare.ml').write_bytes((ROOT/'compare.ml').read_bytes())
    manifest={'sources':{'window_suite.ml':{'source_sha256':digest(suite),'compiled_sha256':digest(transformed)},
        'compare.ml':digest((root/'compare.ml').read_bytes())},
        'actual_units':{p.name:digest(p.read_bytes()) for p in native.iterdir() if p.suffix in ['.ml','.mli','.cmi','.cmx']},
        'prebuilt_archives':{arg:digest(Path(arg).read_bytes()) for arg in link if arg.endswith('.cmxa')}}
    records=[]
    def execute(label,argv,env=None):
        start=time.monotonic()
        p=subprocess.run(argv,cwd=root,env=env,text=True,capture_output=True)
        records.append({'label':label,'argv':argv,'exit_code':p.returncode,'wall_seconds':time.monotonic()-start})
        (root/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
        (root/(label+'.stdout')).write_text(p.stdout)
        (root/(label+'.stderr')).write_text(p.stderr)
        (root/'input-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(label,p.returncode,flush=True)
        if p.returncode:
            print(p.stderr[:6500],flush=True)
            raise SystemExit(p.returncode)
    if not root.name.startswith('cost-'):
        execute('window_suite.ml',prefix+['-c','window_suite.ml'])
        execute('window_suite.link',link+['-o',str(root/'window_suite.exe'),str(native/'window_under_test.cmx'),
            str(native/'codec_under_test.cmx'),str(root/'window_suite.cmx')])
    execute('compare.ml',prefix+['-c','compare.ml'])
    execute('compare.link',link+['-o',str(root/'compare.exe'),str(native/'window_under_base.cmx'),
        str(native/'window_under_test.cmx'),str(native/'codec_under_test.cmx'),str(root/'compare.cmx')])
    manifest['executables']={p.name:digest(p.read_bytes()) for p in [root/'window_suite.exe',root/'compare.exe'] if p.exists()}
    with tempfile.TemporaryDirectory(prefix='masc-owned-snapshot-checks-') as owned:
        env=os.environ.copy();env['MASC_BASE_PATH']=owned
        if (root/'window_suite.exe').exists():
            execute('window_suite.run',[str(root/'window_suite.exe'),'--color=never'],env)
        execute('differential.run',[str(root/'compare.exe'),'differential'],env)
        print((root/'differential.run.stdout').read_text(),flush=True)
        for pair in range(4):
            sides=['baseline','candidate'] if pair%2==0 else ['candidate','baseline']
            for side in sides:
                execute('cost-%d-%s'%(pair+1,side),[str(root/'compare.exe'),side],env)
    print(root.name+' complete',flush=True)

if __name__=='__main__':
    main()
