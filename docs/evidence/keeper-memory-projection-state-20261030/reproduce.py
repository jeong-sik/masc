#!/usr/bin/env python3
"""Compile exact projection functions with explicit isolated dependencies."""
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

def source(rev,path):
    if rev=='WORKTREE': return (root/path).read_text()
    return subprocess.check_output(['git','show',f'{rev}:{path}'],cwd=root,text=True)

directory=out/'compare'
directory.mkdir(exist_ok=True)
(directory/'result.ml').write_text('''include Stdlib.Result
module Syntax = struct let ( let* ) value f = match value with Ok x -> f x | Error e -> Error e end
''')
(directory/'prompt_registry.ml').write_text('''exception Injected_failure
let fail_next = ref false
let set_markdown_dir _ = ()
let render_prompt_template _ fields =
  if !fail_next then (fail_next := false; raise Injected_failure)
  else Ok (List.assoc "payload" fields)
''')
(directory/'prompt_names.ml').write_text('let keeper_context_workspace_memory_host_selected = "fixture"\n')
(directory/'agent_core.ml').write_text('module Error = struct type t = string let to_string x = x end\n')
(directory/'keeper_memory_delivery_reprojection.ml').write_text(
    source(args.candidate,'lib/keeper/keeper_memory_delivery_reprojection.ml'))
string_util=source(args.candidate,'lib/string_util/string_util.ml')
assert string_util==source(args.baseline,'lib/string_util/string_util.ml')
(directory/'string_util.ml').write_text(string_util)
(directory/'masc_test_deps.ml').write_text('let source_path x = x\n')
for label,rev in [('old',args.baseline),('new',args.candidate)]:
    content=source(rev,'lib/keeper/keeper_workspace_memory_host_recall.ml')
    section=content[content.index('let render_payload payload ='):content.index('let prepare_available ')]
    (directory/(label+'_host.ml')).write_text('open Result.Syntax\n'+section+
        '\nmodule For_testing = struct let prepare_projection = make_prepared end\n')

test=source(args.candidate,'test/test_keeper_workspace_memory_selection.ml')
begin=test.index('let test_failed_revalidation_and_receipt_keep_unavailable_projection () =')
end=test.index('\nlet () = Alcotest.run',begin)
case=test[begin:end]
modules=['result.ml','prompt_registry.ml','prompt_names.ml','agent_core.ml',
         'keeper_memory_delivery_reprojection.ml','string_util.ml','masc_test_deps.ml']
for label in ['old','new']:
    (directory/'masc.ml').write_text('module Keeper_workspace_memory_host_recall = '+label.capitalize()+'_host\n')
    (directory/'case.ml').write_text(case+'\nlet () = Alcotest.run "projection" ["failure", [Alcotest.test_case "revalidation and receipt" `Quick test_failed_revalidation_and_receipt_keep_unavailable_projection]]\n')
    subprocess.run(['ocamlfind','ocamlopt','-O3','-package','yojson,alcotest','-linkpkg','-o',label+'_test',
                    *modules,label+'_host.ml','masc.ml','case.ml'],cwd=directory,check=True)
    print('Running extracted repository test against',label,'projection',flush=True)
    subprocess.run(['./'+label+'_test','--color=never'],cwd=directory,check=True)

shutil.copyfile(here/'harness.ml.txt',directory/'harness.ml')
subprocess.run(['ocamlfind','ocamlopt','-O3','-package','yojson,unix','-linkpkg','-o','compare',
                *modules,'old_host.ml','new_host.ml','harness.ml'],cwd=directory,check=True)
subprocess.run(['./compare','samples.csv'],cwd=directory,check=True)
