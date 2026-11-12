open Masc_domain

let rows_changed_observer : (Workspace_utils_backend_setup.config -> unit) Atomic.t =
  Atomic.make (fun _ -> ())

let install_rows_changed_observer observer = Atomic.set rows_changed_observer observer

(* A roster change that is not a record write: a name the workspace state
   lists (or stops listing) as active. *)
let report_roster_changed config = (Atomic.get rows_changed_observer) config

type signal_change = { canonical_masc_root : string; agent_name : string }
type signal_listener = { notify : signal_change -> unit }

let signal_listeners : signal_listener list Atomic.t = Atomic.make []
let signal_failures = Atomic.make 0
let signal_observer_failures () = Atomic.get signal_failures

let subscribe_signal_changed notify =
  let listener = { notify } in
  Lockfree_atomic.update signal_listeners (fun listeners -> listener :: listeners);
  fun () -> Lockfree_atomic.update signal_listeners
    (List.filter (fun current -> current != listener))
;;

let notify_signal change =
  List.iter (fun listener ->
    try listener.notify change with
    (* cancel-guard-ok: this non-yielding after-write observer cannot replace
       an authoritative/uncertain write outcome with a listener exception. *)
    | _ -> ignore (Atomic.fetch_and_add signal_failures 1))
    (Atomic.get signal_listeners)
;;

(* The row the Clients roster draws for one record: listed unless Inactive,
   with its name, type, status, current Task and Keeper. *)
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

let report config ~previous next =
  if not (Option.equal equal_row (Option.bind previous row_of) (row_of next))
  then (Atomic.get rows_changed_observer) config

let signal_changed previous next =
  match previous with
  | None -> true
  | Some previous ->
      not (Option.equal equal_row (row_of previous) (row_of next))
      || not (String.equal previous.last_seen next.last_seen)
      || not (String.equal previous.session_bound_at next.session_bound_at)
      || previous.capabilities <> next.capabilities
;;

let pending_signal config ~previous (agent : agent) =
  if not (signal_changed previous agent) then None
  else Some {
    canonical_masc_root = Fs_compat.realpath_lenient
      (Common.masc_dir_from_base_path ~base_path:config.Workspace_utils_backend_setup.base_path);
    agent_name = agent.name;
  }
;;

let write config path ~previous agent =
  let signal = pending_signal config ~previous agent in
  Fun.protect ~finally:(fun () -> Option.iter notify_signal signal) (fun () ->
    Workspace_utils_ops.write_json config path (agent_to_yojson agent);
    report config ~previous agent)

let write_commit_result config path ~previous agent =
  let signal = pending_signal config ~previous agent in
  Fun.protect ~finally:(fun () -> Option.iter notify_signal signal) (fun () ->
    let result = Workspace_utils_ops.write_json_commit_result config path (agent_to_yojson agent) in
    report config ~previous agent;
    result)
