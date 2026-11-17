from pathlib import Path
import hashlib,json,os,subprocess,sys,tempfile,time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
WORK=Path('/Users/dancer/.codex/worktrees/exact-slot-grouping-20261117/masc')
sha=lambda data:hashlib.sha256(data).hexdigest()

def main():
    out=ROOT/(sys.argv[1] if len(sys.argv)>1 else 'native-r2');out.mkdir()
    (out/'driver.py').write_bytes(Path(__file__).read_bytes())
    old=json.loads((REPO/'artifacts/cpu-memory-20261116/window-shrink-snapshot-20261117/native-r1/commands.json').read_text())
    args=old[0]['argv'];prefix=[args[0],'-I',str(out)]+args[3:-2]
    previous=json.loads((REPO/'artifacts/cpu-memory-20261116/window-shrink-snapshot-20261117/checks-r3/commands.json').read_text())
    link=next(row['argv'] for row in previous if row['label']=='window_suite.link');link=link[:link.index('-o')]
    suite=(WORK/'test/test_server_standalone_lane_projection.ml').read_text()
    def definition(start):
        begin=suite.index(start);end=suite.index('\n;;',begin)+3
        return suite[begin:end]
    helper=definition('let exact_run ')
    case=definition('let test_slot_history_keeps_original_binding_after_republication ')
    manifest={'base':'0542d471eedf56d72cf829b4bd1ad0bf99b417ab','sources':{},'driver_sha256':sha((out/'driver.py').read_bytes()),
      'scope':'Full actual pure projection ML/MLI under fresh basenames; actual maintained helper+entire changed case copied with one leading projection alias; complete-byte differential and owned cost. Real broad prebuilt deps; not full test target/Dune/CI/ABI/runtime.',
      'maintained_full_source_sha256':sha(suite.encode())}
    for side in ['base','test']:
        for suffix in ['mli','ml']:
            data=(ROOT/('original.'+suffix)).read_bytes() if side=='base' else (WORK/('lib/server/server_exact_slot_projection.'+suffix)).read_bytes()
            name='slot_under_'+side+'.'+suffix;(out/name).write_bytes(data);manifest['sources'][name]=sha(data)
        data=('open Alcotest\nmodule Exact = Masc.Exact_lane_run_registry\nmodule Server_exact_slot_projection = Slot_under_'+side+'\n'+helper+'\n'+case+'\n').encode()
        name='maintained_'+side+'.ml';(out/name).write_bytes(data);manifest['sources'][name]=sha(data)
    (out/'probe.ml').write_bytes((ROOT/'probe.ml').read_bytes());manifest['sources']['probe.ml']=sha((out/'probe.ml').read_bytes())
    manifest['extraction']={'helper_sha256':sha(helper.encode()),'complete_case_sha256':sha(case.encode()),'transformation':'Only leading open/module aliases; entire original helper and entire changed maintained case preserved verbatim. No fabricated interface.'}
    manifest['archive_sha256']={arg:sha(Path(arg).read_bytes()) for arg in link if arg.endswith('.cmxa')}
    records=[]
    def run(label,argv,env=None):
        start=time.monotonic();p=subprocess.run(argv,cwd=out,env=env,text=True,capture_output=True)
        records.append({'label':label,'argv':argv,'exit_code':p.returncode,'wall_seconds':time.monotonic()-start})
        (out/(label+'.stdout')).write_text(p.stdout);(out/(label+'.stderr')).write_text(p.stderr)
        (out/'commands.json').write_text(json.dumps(records,indent=2)+'\n');(out/'input-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(label,p.returncode,flush=True)
        if p.returncode:print(p.stderr[:5000],flush=True);raise SystemExit(p.returncode)
    for side in ['base','test']:
        for suffix in ['mli','ml']:run('slot-'+side+'-'+suffix,prefix+['-c','slot_under_'+side+'.'+suffix])
        run('maintained-'+side,prefix+['-c','maintained_'+side+'.ml'])
    run('probe',prefix+['-c','probe.ml'])
    objects=[str(out/name) for name in ['slot_under_base.cmx','slot_under_test.cmx','maintained_base.cmx','maintained_test.cmx','probe.cmx']]
    run('link',link+['-o',str(out/'probe.exe')]+objects)
    manifest['executable_sha256']=sha((out/'probe.exe').read_bytes())
    with tempfile.TemporaryDirectory(prefix='masc-owned-slot-grouping-') as owned:
        env=os.environ.copy();env['MASC_BASE_PATH']=owned
        run('oracle',[str(out/'probe.exe'),'oracle'],env)
        print((out/'oracle.stdout').read_text()[-1000:],flush=True)
        for pair in range(4):
            for side in (['baseline','candidate'] if pair%2==0 else ['candidate','baseline']):
                run('cost-'+str(pair+1)+'-'+side,[str(out/'probe.exe'),side],env)

if __name__=='__main__':main()
