#!/usr/bin/env python3
"""Compare the exact extracted log observation code with minimal dependencies."""
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
    if rev == 'WORKTREE': return (root/path).read_text()
    return subprocess.check_output(['git','show',f'{rev}:{path}'],cwd=root,text=True)

op_path='lib/keeper_chat_operations/keeper_chat_operation.ml'
operation=source(args.candidate,op_path)
assert operation==source(args.baseline,op_path)
failure_kind=operation[operation.index('type failure_kind ='):operation.index('let all_failure_kinds =')]
state_types=operation[operation.index('type failure ='):operation.index('type batch_membership =')]
terminal=operation[operation.index('let is_terminal ='):operation.index('let to_json_with_failure')]

directory=out/'compare'
directory.mkdir(exist_ok=True)
(directory/'keeper_chat_operation.ml').write_text(failure_kind+state_types+terminal)
(directory/'ids.ml').write_text('''module Turn_ref = struct
  type t = string
  let to_string t = t
  let make ~trace_id ~absolute_turn = trace_id ^ string_of_int absolute_turn
end
''')
(directory/'masc.ml').write_text('''module Keeper_chat_events = struct end
module Keeper_chat_event_log = struct type replay_position = Whole_turn end
''')
(directory/'masc_tui_keeper_chat_live.ml').write_text('type delta = unit\n')
for label,rev in [('old',args.baseline),('new',args.candidate)]:
    log=source(rev,'bin/masc_tui_keeper_chat_log.ml')
    prefix=log[:log.index('let decode_operation_state ~operation_id')]
    (directory/(label+'_log.ml')).write_text(prefix)

test_source=source(args.candidate,'test/test_tui_keeper_chat_log.ml')
begin=test_source.index('let test_operation_and_terminal_replay_share_one_observation () =')
end=test_source.index('(* ── v2 page',begin)
case=test_source[begin:end]
for label in ['old','new']:
    (directory/(label+'_test.ml')).write_text(
        'open Alcotest\nmodule Log = '+label.capitalize()+'_log\n'
        'let log () = Log.create ~keeper_name:"keeper.one" ~request_id:"tui-req-1" ~started_at:10.0\n'
        +case+'let () = run "operation replay" ["operation", [test_case "observation" `Quick test_operation_and_terminal_replay_share_one_observation]]\n')
    subprocess.run(['ocamlfind','ocamlopt','-O3','-package','alcotest','-linkpkg','-o',label+'_test',
                    'keeper_chat_operation.ml','ids.ml','masc.ml','masc_tui_keeper_chat_live.ml',
                    label+'_log.ml',label+'_test.ml'],cwd=directory,check=True)
    print('Running extracted repository test against',label,'log',flush=True)
    subprocess.run(['./'+label+'_test','--color=never'],cwd=directory,check=True)

shutil.copyfile(here/'harness.ml.txt',directory/'harness.ml')
subprocess.run(['ocamlfind','ocamlopt','-O3','-package','unix','-linkpkg','-o','compare',
                'keeper_chat_operation.ml','ids.ml','masc.ml','masc_tui_keeper_chat_live.ml',
                'old_log.ml','new_log.ml','harness.ml'],cwd=directory,check=True)
subprocess.run(['./compare','samples.csv'],cwd=directory,check=True)
