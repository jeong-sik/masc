#!/usr/bin/env python3
"""Compare exact Keeper text-stream modules and their extracted test case."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--baseline',required=True)
parser.add_argument('--candidate',required=True)
parser.add_argument('--out',required=True,type=Path)
parser.add_argument('--initial',action='store_true',help='reproduce the first, double-prefix candidate')
args=parser.parse_args()
root=Path(subprocess.check_output(['git','rev-parse','--show-toplevel'],text=True).strip())
here=Path(__file__).resolve().parent
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
def get(rev,path):
    return subprocess.check_output(['git','show',f'{rev}:{path}'],cwd=root,text=True)
module='lib/keeper/keeper_official_client_text_stream.ml'
interface='lib/keeper/keeper_official_client_text_stream.mli'
before=get(args.baseline,module);after=get(args.candidate,module)
mli=get(args.candidate,interface)
assert mli==get(args.baseline,interface)
if args.initial:
    strict='''          if String.starts_with ~prefix:raw final_text then
            (* Equality was handled above, so the raw prefix is strict. *)
            let offset = String.length raw in
            Some (String.sub final_text offset (String.length final_text - offset))
'''
    assert after.count(strict)==1
    after=after.replace(strict,'          if String.starts_with ~prefix:raw final_text then suffix_after ~prefix:raw final_text\n')
    assert hashlib.sha256(after.encode()).hexdigest()=='182484c50d92b5be97210987777de4083fa4f1dc1b8d537fcae1b56e874e8ed7'

test=get(args.candidate,'test/test_runtime_antigravity.ml')
start='let test_keeper_reconciles_raw_current_and_previous_messages () =\n'
end='\nlet test_keeper_reconciles_four_response_steps_and_new_final () =\n'
assert test.count(start)==1 and test.count(end)==1
case=start+test.split(start,1)[1].split(end,1)[0]
case='open Alcotest\n'+case+'\nlet () = Alcotest.run "stream_reconcile" ["response",[Alcotest.test_case "raw current previous" `Quick test_keeper_reconciles_raw_current_and_previous_messages]]\n'
for label,source in [('old',before),('new',after)]:
    path=out/('tests-'+label);path.mkdir(exist_ok=True)
    (path/'keeper_official_client_text_stream.ml').write_text(source)
    (path/'keeper_official_client_text_stream.mli').write_text(mli)
    (path/'test_reconcile.ml').write_text(case)
    subprocess.run(['ocamlfind','ocamlopt','-O3','-package','alcotest','-linkpkg','-o','test_reconcile',
                    'keeper_official_client_text_stream.mli','keeper_official_client_text_stream.ml','test_reconcile.ml'],cwd=path,check=True)
    print('Running extracted case on',label,flush=True)
    subprocess.run(['./test_reconcile','--color=never'],cwd=path,check=True)

path=out/'compare';path.mkdir(exist_ok=True)
(path/'old_stream.ml').write_text(before)
(path/'new_stream.ml').write_text(after)
shutil.copyfile(here/'harness.ml.txt',path/'harness.ml')
subprocess.run(['ocamlfind','ocamlopt','-O3','-package','unix','-linkpkg','-o','harness',
                'old_stream.ml','new_stream.ml','harness.ml'],cwd=path,check=True)
subprocess.run(['./harness','samples.csv'],cwd=path,check=True)
