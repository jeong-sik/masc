#!/usr/bin/env python3
"""Compare exact message-scope helpers inside an explicit small state shim."""
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
(directory/'agent_core.ml').write_text('''module Types = struct
  type api_usage = {token_count:int;charge:float}
  type stop_reason = Stop
end
''')
(directory/'keeper_chat_events.ml').write_text('type kind = Tool_message_start_conflict\n')
for label,rev in [('old',args.baseline),('new',args.candidate)]:
    text=source(rev,'lib/keeper/keeper_stream_tool_accum.ml')
    phase=text[text.index('type stream_phase ='):text.index('type t = {')]
    field='mutable current_message_start:message_start option;'
    info='Option.map (fun start -> start.raw_id,start.model,start.usage) t.current_message_start'
    equal=text[text.index('let current_message_start_equal'):text.index('let current_scope_has_tool_occurrence')]
    if label=='old':
        presence_fields='mutable message_open:bool; mutable message_seen:bool;'
        initial='current_message_start=None;message_open=false;message_seen=false;'
        observed_presence='(t.message_open,t.message_seen)'
        assert text.count('t.message_open <- false') == 5
        close_adapter='let close_message_scope t = t.message_open <- false\n'
    else:
        presence_fields='mutable message_presence:message_presence;'
        initial='current_message_start=None;message_presence=Message_unseen;'
        observed_presence='(match t.message_presence with Message_unseen -> false,false | Message_open -> true,true | Message_closed -> false,true)'
        close_adapter=''
    shim='''type t = { mutable current_stream_scope:int; '''+field+'''
  '''+presence_fields+''' mutable current_scope_progress_seen:bool;
  mutable stream_phase:stream_phase; mutable invalid_indices:int list;
  mutable invalid:bool; mutable has_tool:bool; mutable quarantines:int }
let make () = {current_stream_scope=0;'''+initial+'''
  current_scope_progress_seen=false;stream_phase=Accepting_content;invalid_indices=[];
  invalid=false;has_tool=false;quarantines=0}
let discard_open_scope t _ = t.invalid <- false; t.has_tool <- false
let current_scope_is_invalid t = t.invalid
let current_scope_has_tool_occurrence t = t.has_tool
let quarantine_open_scope t ~kind:_ ~detail:_ = t.quarantines <- t.quarantines + 1
let invalidate_current_scope t = t.invalid <- true
'''
    advance=text[text.index('let advance_to_empty_scope t ='):text.index('let scope_is_sealed')]
    methods=text[text.index('let prepare_message_start t'):text.index('let finalized_at_current_index')]
    begin=text.rindex('let provider_message_id =')
    end=text.index('let finalized_at_index =',begin)
    provider=text[begin:end]
    wrapper='''let provider_id t =\n  '''+provider+'''  provider_message_id
let observation t = (t.current_stream_scope,'''+info+''','''+observed_presence+''',
  t.current_scope_progress_seen,t.stream_phase,t.invalid_indices,t.invalid,t.has_tool,t.quarantines)
let set_progress t value = t.current_scope_progress_seen <- value
let set_tool t value = t.has_tool <- value
let set_phase t = function 0 -> t.stream_phase <- Accepting_content
 | 1 -> t.stream_phase <- Stop_reason_seen Agent_core.Types.Stop
 | _ -> t.stream_phase <- Message_stopped
'''
    (directory/(label+'_state.ml')).write_text(phase+shim+advance+equal+methods+close_adapter+wrapper)
shutil.copyfile(here/'harness.ml.txt',directory/'harness.ml')
subprocess.run(['ocamlfind','ocamlopt','-O3','-package','unix','-linkpkg','-o','compare',
                'agent_core.ml','keeper_chat_events.ml','old_state.ml','new_state.ml','harness.ml'],
               cwd=directory,check=True)
subprocess.run(['./compare','samples.csv'],cwd=directory,check=True)
