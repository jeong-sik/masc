from pathlib import Path
import subprocess
import json
import hashlib

root=Path.cwd()
out=Path(__file__).resolve().parent
base=subprocess.run(['git','rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip()
old=subprocess.run(['git','show',base+':bin/masc_tui_keeper_control.ml'],capture_output=True,text=True,check=True).stdout
new=(root/'bin/masc_tui_keeper_control.ml').read_text()
interface=(root/'bin/masc_tui_keeper_control.mli').read_text()

def section(text,start,end):
    at=text.index(start)
    return text[at:text.index(end,at)]

action=section(new,'type action =','(* One key each')
(out/'fixture_types.ml').write_text('''module Decode = struct
  type keeper_runtime = { kr_name : string; runtime_identity : int;
                          kr_keepalive_running : bool }
end
module Control = struct
  type liveness = Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
  type reading = { name : string; paused : bool; liveness : liveness }
'''+action+'end\n')
prefix='''module Decode = Fixture_types.Decode
type liveness = Fixture_types.Control.liveness =
  | Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
type reading = Fixture_types.Control.reading =
  { name : string; paused : bool; liveness : liveness }
'''
aliased_action=action.replace('type action =','type action = Fixture_types.Control.action =',1)
for label,source in [('baseline',old),('candidate',new)]:
    start='type roster_view =' if label=='candidate' else 'type roster ='
    roster=section(source,start,'type roster_failure =')
    getter=section(source,'let liveness_of_roster roster name =','(* One keeper, four separate readings')
    if label=='baseline':getter=section(source,'let find_row rows name =','(* One keeper, four separate readings')
    decisions=section(source,'let runs reading =','let primary reading =')
    (out/('actual_control_'+label+'.ml')).write_text(prefix+roster+getter+aliased_action+decisions)
signature=section(interface,'type roster_view =','(** Why the roster reading is missing.')
signature=signature.replace('Masc.Tui_decode.keeper_runtime','Decode.keeper_runtime')
(out/'actual_control_candidate.mli').write_text(prefix+signature+
    'val liveness_of_roster : roster -> string -> liveness\n'+aliased_action+
    'val runs : reading -> bool option\nval available : reading -> action list\n')
inputs=[]
for file in ['bin/masc_tui_keeper_control.ml','bin/masc_tui_keeper_control.mli','bin/masc_tui.ml','bin/masc_tui_types.ml','bin/masc_tui_render_config.ml','bin/masc_tui_render_keepers.ml','test/test_tui_keeper_control.ml','test/test_tui_server_identity_refresh.ml']:
    inputs.append({'file':file,'sha256':hashlib.sha256((root/file).read_bytes()).hexdigest()})
(out/'source-identity-v1.json').write_text(json.dumps({
    'base':base,'scope':'Exact roster factory/view/getter and lifecycle-decision fragments; reduced runtime records and shared type aliases. Not the full module, wire decode, test suite, workspace admission or TUI execution.',
    'inputs':inputs,
},indent=2)+'\n')
