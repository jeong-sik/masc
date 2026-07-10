(** Typed model of [/api/v1/dashboard/shell] responses.

    Subset of the full shell JSON — pick only what the Overview view
    actually renders. Full schema in [lib/server/server_dashboard_http_core.ml].

    Shape is manually parsed from [Yojson.Safe.t] — no ppx crossing into
    js_of_ocaml. *)

open! Core

type build =
  { release_version : string
  ; commit : string
  ; started_at : string
  ; uptime_seconds : int
  }

type status =
  { cluster : string
  ; project : string
  ; version : string
  ; paused : bool
  ; tempo_interval_s : float
  ; build : build
  }

type counts =
  { agents : int
  ; tasks : int
  ; keepers : int
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
  ; status : status
  ; counts : counts
  ; configured_keepers : int
  ; base_path : string
  ; fetch_status : fetch_status
  }

let fixture_build : build =
  { release_version = ""; commit = ""; started_at = ""; uptime_seconds = 0 }
;;

let fixture_status : status =
  { cluster = ""
  ; project = ""
  ; version = ""
  ; paused = false
  ; tempo_interval_s = 0.0
  ; build = fixture_build
  }
;;

let fixture_counts : counts = { agents = 0; tasks = 0; keepers = 0 }

let fixture : response =
  { generated_at = ""
  ; status = fixture_status
  ; counts = fixture_counts
  ; configured_keepers = 0
  ; base_path = ""
  ; fetch_status = Fetch_pending
  }
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

let build_of_yojson json : build =
  { release_version = string_field json "release_version"
  ; commit = string_field json "commit"
  ; started_at = string_field json "started_at"
  ; uptime_seconds = int_field json "uptime_seconds"
  }
;;

let status_of_yojson json : status =
  let build_json = Yojson.Safe.Util.member "build" json in
  { cluster = string_field json "cluster"
  ; project = string_field json "project"
  ; version = string_field json "version"
  ; paused = bool_field json "paused"
  ; tempo_interval_s = float_field json "tempo_interval_s"
  ; build = build_of_yojson build_json
  }
;;

let counts_of_yojson json : counts =
  { agents = int_field json "agents"
  ; tasks = int_field json "tasks"
  ; keepers = int_field json "keepers"
  }
;;

let response_of_yojson json : response =
  let base_path =
    match Yojson.Safe.Util.member "paths" json with
    | `Assoc _ as p -> string_field p "effective_base_path"
    | _ -> string_field (Yojson.Safe.Util.member "status" json) "base_path"
  in
  { generated_at = string_field json "generated_at"
  ; status = status_of_yojson (Yojson.Safe.Util.member "status" json)
  ; counts = counts_of_yojson (Yojson.Safe.Util.member "counts" json)
  ; configured_keepers = int_field json "configured_keepers"
  ; base_path
  ; fetch_status = Fetch_fresh
  }
;;

let fetch_status_label = function
  | Fetch_pending -> "fetch pending"
  | Fetch_fresh -> "fetch ok"
  | Fetch_stale { consecutive_failures; _ } ->
    Printf.sprintf "stale %dx" consecutive_failures
;;
