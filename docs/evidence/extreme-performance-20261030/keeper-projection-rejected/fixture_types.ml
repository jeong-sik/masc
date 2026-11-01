module Masc_domain = struct
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
type liveness =
  | Unobserved
  | Invalid of string
  | Absent
  | Present of Decode.keeper_runtime

type reading = {
  name : string;
  paused : bool;
  liveness : liveness;
}

type roster =
  | Roster_unobserved
  | Roster_partial of
      { observed : Decode.keeper_runtime list
      ; total : int
      }
  | Roster_invalid of
      { observed : Decode.keeper_runtime list
      ; errors : (string * string) list
      ; complete : bool
      }
  | Roster_complete of Decode.keeper_runtime list

let roster_of_reading ~errors ~rows ~truncated ~total =
  (* [count] short of [total] is the same fact as truncation: rows that belong
     here are missing. The route drops a keeper whose metadata it cannot read,
     and that keeper's fiber is still running. *)
  let observed_count = List.length rows in
  if errors <> [] then
    Roster_invalid { observed = rows; errors;
      complete = not truncated && observed_count + List.length errors >= total }
  else if truncated || observed_count < total then
    Roster_partial { observed = rows; total = max total observed_count }
  else Roster_complete rows

end
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
