from pathlib import Path
import hashlib
import json
import subprocess

root = Path.cwd()
out = Path(__file__).resolve().parent
base = subprocess.run(['git','rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip()
inputs = []


def source(filename, candidate):
    data = ((root / filename).read_bytes() if candidate else
            subprocess.run(['git','show',base+':'+filename],capture_output=True,check=True).stdout)
    inputs.append({'file':filename,'candidate':candidate,'base':base,
                   'sha256':hashlib.sha256(data).hexdigest()})
    return data.decode()


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


control = source('bin/masc_tui_keeper_control.ml', False)
types = between(control, 'type liveness =', 'type roster_failure =')
fixture = '''module Masc_domain = struct
  type task_status = Todo | Claimed of unit | InProgress of unit
    | AwaitingVerification of { assignee : string }
    | Done of unit | Cancelled of unit
end
module Tui_decode = struct
  type keeper_origin = Declared_keeper of string | Persisted_keeper | Remote_keeper
  type keeper_runtime = { kr_name : string; runtime_identity : int }
  type activity = { k_current_task_id : string option }
  type keeper = { k_name : string; k_paused : bool; k_origin : keeper_origin;
                  k_activity : activity option; source_identity : int }
  type keeper_turn_state = Turn of int
  type keeper_turn_row = { ktr_keeper_name : string; ktr_state : keeper_turn_state }
  type keeper_waiting_row = { kwr_keeper_name : string; waiting_identity : int }
  type keeper_tool_approval = { kta_keeper : string; approval_identity : int }
  type task = { id : string; status : Masc_domain.task_status; task_identity : int }
  type async_request_row = { ar_keeper_name : string; async_identity : int }
  type async_observation = Async_ready of { requests : async_request_row list }
    | Async_unavailable of string
end
module Decode = Tui_decode
module Control = struct
''' + types + '''end
module Masc = struct
  module Tui_decode_asks = struct
    type asker = Ask_keeper of string | Ask_installation of string
    type row = { ar_asker : asker }
    type snapshot = { asn_rows : row list }
  end
end
module Model = struct
  type waiting_reading = Waiting_unavailable | Waiting_observed of Tui_decode.keeper_waiting_row | Waiting_unobserved
  type row = {
    keeper : Tui_decode.keeper; reading : Control.reading;
    turn : Tui_decode.keeper_turn_state option; waiting : waiting_reading;
    approval : Tui_decode.keeper_tool_approval option; task : Tui_decode.task option;
    awaiting_verification : bool; open_questions : int;
    async_requests : Tui_decode.async_request_row list; last_activity_at : float option }
  let order_rows ~layout:() ~sort:() rows = rows
  let holds_awaiting_verification ~keeper_name tasks =
    List.exists (fun (task : Tui_decode.task) -> match task.status with
      | Masc_domain.AwaitingVerification {assignee} -> String.equal assignee keeper_name
      | Masc_domain.Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> false) tasks
end
type keeper = Tui_decode.keeper
type state = {
  keepers : keeper list; keeper_roster : Control.roster;
  keeper_turns : Tui_decode.keeper_turn_row list;
  keeper_waiting : Tui_decode.keeper_waiting_row list;
  keeper_waiting_failure : string option;
  keeper_tool_approvals : Tui_decode.keeper_tool_approval list;
  tasks : Tui_decode.task list;
  asks_snapshot : Masc.Tui_decode_asks.snapshot option;
  tools_async_observation : Tui_decode.async_observation option;
  keeper_list_layout : unit; keeper_list_sort : unit }
let keeper_activity_at ~turn ~waiting keeper =
  ignore (turn, waiting, keeper); None
'''
(out / 'fixture_types.ml').write_text(fixture)
for candidate, name in [(False, 'baseline'), (True, 'candidate')]:
    c = source('bin/masc_tui_keeper_control.ml',candidate)
    end = '(* One keeper, four separate readings'
    c = between(c,'let find_row rows name =',end)
    (out / ('control_'+name+'.ml')).write_text('open Fixture_types\ninclude Control\n'+c)
    t = source('bin/masc_tui_types.ml',candidate)
    readings = between(t,'let keeper_reading (state : state)', 'let keeper_last_turn_at')
    start = 'module Keeper_projection_names =' if candidate else 'let keeper_list_rows (state : state)'
    projection = between(t,start,'let ordered_keepers state =')
    prefix = ('open Fixture_types\nmodule Masc_tui_keeper_control = Control_'+name+'\n'
              'module Masc_tui_keeper_list_model = Model\n')
    (out / ('projection_'+name+'.ml')).write_text(prefix+readings+projection)
(out / 'source-identity.json').write_text(json.dumps({
    'scope':'Exact product source fragments compiled against reduced typed fixture records. Date/activity projection and sorting are stubbed identically and excluded from timing. This is a component lookup/preparation experiment, not a full module/TUI compile, screen ordering test, native fleet benchmark or target proof.',
    'inputs':inputs,
},indent=2)+'\n')
