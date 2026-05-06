(** Typed model of [/dashboard/b/api/keepers/summary] responses.

    Mirror of [lib/dashboard_api_types/keepers.ml] (the server SSOT), parsed
    manually with Yojson.Safe.Util to keep the client ppx surface small.
    Server uses [ppx_deriving_yojson] — client does not carry that ppx into
    js_of_ocaml compilation. Shape must stay in lock-step with the server
    record. *)

type keeper_status =
  | Live
  | Warn
  | Dead

type fetch_status =
  | Fetch_pending
  | Fetch_fresh
  | Fetch_stale of
      { reason : string
      ; consecutive_failures : int
      }

type lane_frame =
  { kind : string              (* "llm" | "tool" | "think" | "wait" | "err" *)
  ; left : int                 (* left %, 0..100 *)
  ; width : int                (* width %, 0..100 *)
  ; label : string
  }

type ctx_sample =
  { t_minus_min : int           (* minutes ago, 0..60 *)
  ; ctx_pct : int               (* 0..100 *)
  }

type keeper =
  { name : string
  ; stat : string               (* human state: "reading", "retrying" *)
  ; status : keeper_status
  ; ctx_pct : int
  ; turn : int
  ; turn_cap : int
  ; mem_kb : int
  ; latency_ms : int
  ; last_tool : string option
  ; lane_frames : lane_frame list
  ; ctx_history : ctx_sample list
  }

type response =
  { keepers : keeper list
  ; cycle : int
  ; room : string option
  ; generated_at : string        (* ISO-8601 UTC *)
  ; fetch_status : fetch_status
  }

(* ---------- manual Yojson decoding ---------- *)

let string_field ?(default = "") json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default
;;

let int_field ?(default = 0) json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> i
  | `Intlit s -> (try int_of_string s with _ -> default)
  | _ -> default
;;

let string_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None
;;

let status_of_string = function
  | "Live" -> Live
  | "Warn" -> Warn
  | "Dead" -> Dead
  | _ -> Warn
;;

let status_of_yojson json =
  match json with
  | `String s -> status_of_string s
  | `List [ `String s ] -> status_of_string s  (* ppx variant fallback *)
  | _ -> Warn
;;

let lane_frame_of_yojson json =
  { kind = string_field json "kind"
  ; left = int_field json "left"
  ; width = int_field json "width"
  ; label = string_field json "label"
  }
;;

let ctx_sample_of_yojson json =
  { t_minus_min = int_field json "t_minus_min"
  ; ctx_pct = int_field json "ctx_pct"
  }
;;

let list_field f json key =
  match Yojson.Safe.Util.member key json with
  | `List xs -> List.map f xs
  | _ -> []
;;

let keeper_of_yojson json =
  { name = string_field json "name"
  ; stat = string_field json "stat"
  ; status = status_of_yojson (Yojson.Safe.Util.member "status" json)
  ; ctx_pct = int_field json "ctx_pct"
  ; turn = int_field json "turn"
  ; turn_cap = int_field ~default:60 json "turn_cap"
  ; mem_kb = int_field json "mem_kb"
  ; latency_ms = int_field json "latency_ms"
  ; last_tool = string_opt_field json "last_tool"
  ; lane_frames = list_field lane_frame_of_yojson json "lane_frames"
  ; ctx_history = list_field ctx_sample_of_yojson json "ctx_history"
  }
;;

let response_of_yojson json =
  { keepers = list_field keeper_of_yojson json "keepers"
  ; cycle = int_field json "cycle"
  ; room = string_opt_field json "room"
  ; generated_at = string_field json "generated_at"
  ; fetch_status = Fetch_fresh
  }
;;

let fetch_status_label = function
  | Fetch_pending -> "fetch · pending"
  | Fetch_fresh -> "fetch · ok"
  | Fetch_stale { consecutive_failures; _ } ->
    Printf.sprintf "stale · %dx" consecutive_failures
;;

let fetch_status_reason = function
  | Fetch_pending -> "waiting for first keeper summary"
  | Fetch_fresh -> "latest keeper summary parsed"
  | Fetch_stale { reason; _ } -> reason
;;

(** Initial placeholder — empty keepers list. Views should degrade gracefully
    (show "— no data —" or fall back to the static mock) when rendered with
    this fixture. *)
let fixture : response =
  { keepers = []
  ; cycle = 0
  ; room = None
  ; generated_at = ""
  ; fetch_status = Fetch_pending
  }
;;
