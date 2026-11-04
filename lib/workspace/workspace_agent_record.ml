open Masc_domain

type row =
  { name : string
  ; agent_type : string
  ; status : agent_status
  ; current_task : string option
  ; keeper_name : string option
  }

let equal_status left right =
  match left, right with
  | Active, Active | Busy, Busy | Listening, Listening | Inactive, Inactive -> true
  | (Active | Busy | Listening | Inactive), (Active | Busy | Listening | Inactive) -> false

let equal_row left right =
  String.equal left.name right.name
  && String.equal left.agent_type right.agent_type
  && equal_status left.status right.status
  && Option.equal String.equal left.current_task right.current_task
  && Option.equal String.equal left.keeper_name right.keeper_name

let row_of (agent : agent) =
  match agent.status with
  | Inactive -> None
  | Active | Busy | Listening ->
    Some
      { name = agent.name
      ; agent_type = agent.agent_type
      ; status = agent.status
      ; current_task = agent.current_task
      ; keeper_name = Option.bind agent.meta (fun (meta : agent_meta) -> meta.keeper_name)
      }

let rows_changed_observer : (Workspace_utils_backend_setup.config -> unit) Atomic.t =
  Atomic.make (fun _ -> ())

let install_rows_changed_observer observer = Atomic.set rows_changed_observer observer

let report config ~previous next =
  if not (Option.equal equal_row (Option.bind previous row_of) (row_of next))
  then (Atomic.get rows_changed_observer) config

let write config path ~previous agent =
  Workspace_utils_ops.write_json config path (agent_to_yojson agent);
  report config ~previous agent

let write_commit_result config path ~previous agent =
  let result = Workspace_utils_ops.write_json_commit_result config path (agent_to_yojson agent) in
  report config ~previous agent;
  result
