#!/usr/bin/env python3
"""Compile the exact fetched module, interface and tests; compare accessor variants."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--baseline',required=True)
parser.add_argument('--candidate',required=True)
parser.add_argument('--out',required=True,type=Path)
args=parser.parse_args()
root=Path(subprocess.check_output(['git','rev-parse','--show-toplevel'],text=True).strip())
here=Path(__file__).resolve().parent
out=args.out.resolve()
out.mkdir(parents=True,exist_ok=True)
def file_at(rev,path):
    return subprocess.check_output(['git','show',f'{rev}:{path}'],cwd=root,text=True)

module='bin/masc_tui_fetched.ml'
interface='bin/masc_tui_fetched.mli'
test='test/test_tui_fetched.ml'
old=file_at(args.baseline,module)
candidate=file_at(args.candidate,module)
mli=file_at(args.candidate,interface)
assert mli == file_at(args.baseline,interface)
test_source=file_at(args.candidate,test)
for label,source in [('old',old),('new',candidate)]:
    path=out/('tests-'+label)
    path.mkdir(exist_ok=True)
    (path/'masc_tui_fetched.ml').write_text(source)
    (path/'masc_tui_fetched.mli').write_text(mli)
    (path/'test_tui_fetched.ml').write_text(test_source)
    subprocess.run(['ocamlfind','ocamlopt','-O3','-package','alcotest','-linkpkg','-o','test_fetched',
                    'masc_tui_fetched.mli','masc_tui_fetched.ml','test_tui_fetched.ml'],cwd=path,check=True)
    print('Running',label,'module tests',flush=True)
    subprocess.run(['./test_fetched','--color=never'],cwd=path,check=True)

old_key='let current_key state = Option.map fst (current state)\n\n'
assert old.count(old_key)==1
without=old.replace(old_key,'')
marker='let view_for ~equal state ~key =\n'
assert without.count(marker)==1
via=without.replace(marker,'let current_key state = Option.map request_key (current_request state)\n\n'+marker)
assert via == candidate
direct='''let current_key state =
  match state.status with
  | Status_absent -> None
  | Status_loading request | Status_ready (request, _)
  | Status_retrying (request, _)
  | Status_refreshing (request, _, _) | Status_stale (request, _, _)
  | Status_failed (request, _) -> Some request.key
;;

'''
request='''let current_request state =
  match state.status with
  | Status_absent -> None
  | Status_loading request | Status_ready (request, _)
  | Status_retrying (request, _)
  | Status_refreshing (request, _, _) | Status_stale (request, _, _)
  | Status_failed (request, _) -> Some request
;;

'''
project='''let current_request_with state ~project =
  match state.status with
  | Status_absent -> None
  | Status_loading request | Status_ready (request, _)
  | Status_retrying (request, _)
  | Status_refreshing (request, _, _) | Status_stale (request, _, _)
  | Status_failed (request, _) -> Some (project request)
;;

let current_request state = current_request_with state ~project:Fun.id
let current_key state = current_request_with state ~project:request_key

'''
assert without.count(request)==1
variants=[('old_fetched.ml',old),('via_request_fetched.ml',via),
          ('direct_fetched.ml',without.replace(marker,direct+marker)),
          ('project_fetched.ml',without.replace(request,project))]
path=out/'compare'
path.mkdir(exist_ok=True)
for name,source in variants:
    (path/name).write_text(source)
shutil.copyfile(here/'harness.ml.txt',path/'harness.ml')
subprocess.run(['ocamlfind','ocamlopt','-O3','-package','unix','-linkpkg','-o','benchmark',
                *(name for name,_ in variants),'harness.ml'],cwd=path,check=True)
subprocess.run(['./benchmark','key-samples.csv','request-samples.csv'],cwd=path,check=True)
