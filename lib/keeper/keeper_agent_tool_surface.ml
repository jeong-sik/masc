(** Keeper turn-lane telemetry and backlog task reconciliation. *)

(* Closed sum type for turn_lane.  Two producers emit values:
   - keeper_run_tools.ml emits the per-turn lanes
     (text_only, tool_optional, tool_disabled, retry).
   - keeper_turn_helpers.pre_dispatch_tool_surface emits the
     [Lane_pre_dispatch] placeholder before the per-turn lane logic
     runs.
   No [@@deriving tla] because this is a small runtime-local lane
   label, not a spec catalog. *)
type turn_lane =
  | Lane_pre_dispatch
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

let turn_lane_to_string = function
  | Lane_pre_dispatch -> "pre_dispatch"
  | Lane_text_only -> "text_only"
  | Lane_tool_optional -> "tool_optional"
  | Lane_tool_disabled -> "tool_disabled"
  | Lane_retry -> "retry"

let turn_lane_of_string = function
  | "pre_dispatch" -> Some Lane_pre_dispatch
  | "text_only" -> Some Lane_text_only
  | "tool_optional" -> Some Lane_tool_optional
  | "tool_disabled" -> Some Lane_tool_disabled
  | "retry" -> Some Lane_retry
  | _ -> None

let turn_lane_to_yojson lane = `String (turn_lane_to_string lane)

type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

let owned_active_task_id_for_meta =
  Keeper_current_task_reconcile.owned_active_task_id_for_meta

let merge_current_task_id =
  Keeper_current_task_reconcile.merge_current_task_id

let sync_current_task_id_from_backlog =
  Keeper_current_task_reconcile.sync_current_task_id_from_backlog

let sync_current_task_id_for_agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name

let tool_names =
  List.map Keeper_tool_name.to_string

module StringSet = Set_util.StringSet

type activation_error =
  | Duplicate_registered_name of string
  | Duplicate_initial_name of string
  | Unknown_initial_name of string
  | Unknown_activation_name of string

type active_tool_surface =
  { registered_names : string list
  ; registered_set : StringSet.t
  ; mutex : Stdlib.Mutex.t
  ; mutable active_set : StringSet.t
  }

let add_unique ~duplicate names =
  let rec add set = function
    | [] -> Ok set
    | name :: rest ->
      if StringSet.mem name set
      then Error (duplicate name)
      else add (StringSet.add name set) rest
  in
  add StringSet.empty names
;;

let create_active_tool_surface ~registered_names ~initial_names =
  match add_unique ~duplicate:(fun name -> Duplicate_registered_name name) registered_names with
  | Error _ as error -> error
  | Ok registered_set ->
    (match add_unique ~duplicate:(fun name -> Duplicate_initial_name name) initial_names with
     | Error _ as error -> error
     | Ok active_set ->
       (match List.find_opt (fun name -> not (StringSet.mem name registered_set)) initial_names with
        | Some name -> Error (Unknown_initial_name name)
        | None ->
          Ok
            { registered_names
            ; registered_set
            ; mutex = Stdlib.Mutex.create ()
            ; active_set
            }))
;;

let activate_exact surface ~names =
  Stdlib.Mutex.protect surface.mutex (fun () ->
    match List.find_opt (fun name -> not (StringSet.mem name surface.registered_set)) names with
    | Some name -> Error (Unknown_activation_name name)
    | None ->
      surface.active_set
      <- List.fold_left
           (fun active name -> StringSet.add name active)
           surface.active_set
           names;
      Ok ())
;;

let active_names surface =
  Stdlib.Mutex.protect surface.mutex (fun () ->
    List.filter (fun name -> StringSet.mem name surface.active_set) surface.registered_names)
;;

let is_active surface name =
  Stdlib.Mutex.protect surface.mutex (fun () -> StringSet.mem name surface.active_set)
