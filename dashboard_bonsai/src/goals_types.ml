(** Typed model of [/api/v1/dashboard/goals] responses.

    Mirrors [lib/dashboard/dashboard_goals.ml:dashboard_goals_tree_json].
    Recursive tree of goal nodes; each node carries its immediate task
    list. [fetch_status] is client-local polling state and is not emitted by
    the server. *)

open! Core

type task =
  { id : string
  ; title : string
  ; status : string         (* pending / claimed / in_progress / completed / cancelled *)
  ; priority : int
  ; assignee : string option
  ; is_terminal : bool
  }

type node =
  { id : string
  ; title : string
  ; status : string          (* active / paused / done / ... *)
  ; priority : int
  ; metric : string option
  ; target_value : string option
  ; due_date : string option
  ; tasks : task list
  ; task_count : int
  ; task_done_count : int
  ; stagnation_seconds : int option
  ; latest_keeper_ref : string option
  ; latest_turn_ref : int option
  ; children : node list
  ; child_count : int
  }

type summary =
  { total_goals : int
  ; active_goals : int
  ; total_tasks : int
  ; done_tasks : int
  }

type fetch_status =
  | Fetch_pending
  | Fetch_fresh
  | Fetch_stale of
      { reason : string
      ; consecutive_failures : int
      }

type response =
  { generated_at : string
  ; tree : node list
  ; summary : summary
  ; fetch_status : fetch_status
  }

let fixture_summary : summary =
  { total_goals = 0
  ; active_goals = 0
  ; total_tasks = 0
  ; done_tasks = 0
  }
;;

let fixture : response =
  { generated_at = ""; tree = []; summary = fixture_summary; fetch_status = Fetch_pending }
;;

(* ---------- manual Yojson decoding ---------- *)

let string_field ?(default = "") json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default
;;

let int_field ?(default = 0) json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> i
  | `Intlit s -> (try Int.of_string s with _ -> default)
  | _ -> default
;;

let string_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None
;;

let int_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Some i
  | `Intlit s -> (try Some (Int.of_string s) with _ -> None)
  | _ -> None
;;

let bool_field ?(default = false) json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> b
  | _ -> default
;;

let task_of_yojson json : task =
  { id = string_field json "id"
  ; title = string_field json "title"
  ; status = string_field json "status"
  ; priority = int_field json "priority"
  ; assignee = string_opt_field json "assignee"
  ; is_terminal = bool_field json "is_terminal"
  }
;;

let rec node_of_yojson json : node =
  let tasks =
    match Yojson.Safe.Util.member "tasks" json with
    | `List xs -> List.map xs ~f:task_of_yojson
    | _ -> []
  in
  let children =
    match Yojson.Safe.Util.member "children" json with
    | `List xs -> List.map xs ~f:node_of_yojson
    | _ -> []
  in
  { id = string_field json "id"
  ; title = string_field json "title"
  ; status = string_field json "status"
  ; priority = int_field json "priority"
  ; metric = string_opt_field json "metric"
  ; target_value = string_opt_field json "target_value"
  ; due_date = string_opt_field json "due_date"
  ; tasks
  ; task_count = int_field json "task_count"
  ; task_done_count = int_field json "task_done_count"
  ; stagnation_seconds = int_opt_field json "stagnation_seconds"
  ; latest_keeper_ref = string_opt_field json "latest_keeper_ref"
  ; latest_turn_ref =
      (match Yojson.Safe.Util.member "latest_turn_ref" json with
       | `Int i -> Some i
       | `Intlit s -> (try Some (Int.of_string s) with _ -> None)
       | _ -> None)
  ; children
  ; child_count = int_field json "child_count"
  }
;;

let summary_of_yojson json : summary =
  { total_goals = int_field json "total_goals"
  ; active_goals = int_field json "active_goals"
  ; total_tasks = int_field json "total_tasks"
  ; done_tasks = int_field json "done_tasks"
  }
;;

let is_response_envelope json =
  match Yojson.Safe.Util.member "tree" json, Yojson.Safe.Util.member "summary" json with
  | `List _, `Assoc _ -> true
  | _ -> false
;;

let response_of_yojson json : response =
  let tree =
    match Yojson.Safe.Util.member "tree" json with
    | `List xs -> List.map xs ~f:node_of_yojson
    | _ -> []
  in
  let summary =
    match Yojson.Safe.Util.member "summary" json with
    | `Assoc _ as s -> summary_of_yojson s
    | _ -> fixture_summary
  in
  { generated_at = string_field json "generated_at"; tree; summary; fetch_status = Fetch_fresh }
;;

let fetch_status_label = function
  | Fetch_pending -> "fetch pending"
  | Fetch_fresh -> "fetch fresh"
  | Fetch_stale { consecutive_failures; _ } ->
    Printf.sprintf "fetch stale x%d" consecutive_failures
;;

let fetch_status_reason = function
  | Fetch_pending -> "waiting for first goals response"
  | Fetch_fresh -> "latest goals response parsed"
  | Fetch_stale { reason; _ } -> reason
;;
