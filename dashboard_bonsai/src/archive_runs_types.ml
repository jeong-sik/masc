(** Typed model of [/api/v1/autoresearch/loops] responses.

    Manual Yojson.Safe.Util parsing to keep the client ppx surface small
    (no [ppx_deriving_yojson] crossing into js_of_ocaml). Shape mirrors
    [lib/dashboard/dashboard_http_autoresearch.ml:autoresearch_loops_json]. *)

open! Core

type status =
  | Running
  | Stopped
  | Paused
  | Failed
  | Completed
  | Unknown

type loop =
  { loop_id : string
  ; goal : string
  ; status : status
  ; current_cycle : int
  ; max_cycles : int
  ; best_score : float
  ; target_reached : bool
  ; total_keeps : int
  ; total_discards : int
  ; elapsed_s : float
  ; updated_at : float               (* unix seconds *)
  ; live : bool
  ; error : string option
  ; target_file : string
  }

type fetch_status =
  | Fetch_pending
  | Fetch_fresh
  | Fetch_stale of
      { reason : string
      ; consecutive_failures : int
      }

type response =
  { loops : loop list
  ; total : int
  ; offset : int
  ; limit : int
  ; fetch_status : fetch_status
  }

let fixture : response =
  { loops = []; total = 0; offset = 0; limit = 100; fetch_status = Fetch_pending }

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

let float_field ?(default = 0.0) json key =
  match Yojson.Safe.Util.member key json with
  | `Float f -> f
  | `Int i -> Float.of_int i
  | `Intlit s -> (try Float.of_string s with _ -> default)
  | _ -> default
;;

let bool_field ?(default = false) json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> b
  | _ -> default
;;

let string_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | `Null -> None
  | _ -> None
;;

let status_of_string = function
  | "running" -> Running
  | "stopped" -> Stopped
  | "paused" -> Paused
  | "failed" -> Failed
  | "completed" -> Completed
  | _ -> Unknown
;;

let loop_of_yojson json : loop =
  { loop_id = string_field json "loop_id"
  ; goal = string_field json "goal"
  ; status = status_of_string (string_field ~default:"unknown" json "status")
  ; current_cycle = int_field json "current_cycle"
  ; max_cycles = int_field json "max_cycles"
  ; best_score = float_field json "best_score"
  ; target_reached = bool_field json "target_reached"
  ; total_keeps = int_field json "total_keeps"
  ; total_discards = int_field json "total_discards"
  ; elapsed_s = float_field json "elapsed_s"
  ; updated_at = float_field json "updated_at"
  ; live = bool_field json "live"
  ; error = string_opt_field json "error"
  ; target_file = string_field json "target_file"
  }
;;

let response_of_yojson json : response =
  let loops =
    match Yojson.Safe.Util.member "loops" json with
    | `List xs -> List.map xs ~f:loop_of_yojson
    | _ -> []
  in
  { loops
  ; total = int_field json "total"
  ; offset = int_field json "offset"
  ; limit = int_field ~default:100 json "limit"
  ; fetch_status = Fetch_fresh
  }
;;

let status_label = function
  | Running -> "running"
  | Stopped -> "stopped"
  | Paused -> "paused"
  | Failed -> "failed"
  | Completed -> "completed"
  | Unknown -> "—"
;;

let fetch_status_label = function
  | Fetch_pending -> "fetch pending"
  | Fetch_fresh -> "fetch ok"
  | Fetch_stale { consecutive_failures; _ } ->
    Printf.sprintf "stale %dx" consecutive_failures
;;
