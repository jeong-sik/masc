(** Typed model of [/api/v1/dashboard/logs] responses.

    The server's current JSON shape is defined in [lib/masc_log/log.ml] and
    emitted by [lib/server/server_routes_http_routes_dashboard.ml]. Field set
    and defaults are copied verbatim from [Log.Ring.to_json] so this client
    is pixel-compatible with the Preact dashboard's log table.

    Parsers are manual (no ppx) to keep Phase 1a ppx surface small. Phase 1b
    will swap in ppx_yojson_conv once the real fetch layer lands. *)

type entry =
  { seq : int
  ; ts : string                  (* ISO8601 UTC, e.g. "2026-04-19T14:32:15Z" *)
  ; level : string               (* canonical level — always set *)
  ; source : string              (* "structured" | "startup_console" | "client_tool_host" *)
  ; module_ : string             (* JSON field "module" — reserved keyword *)
  ; message : string
  ; details : string option      (* raw JSON string — parsed lazily by callers *)
  }

type response =
  { total : int
  ; entries : entry list
  ; fetch_status : fetch_status
  }

and fetch_status =
  | Fetch_pending
  | Fetch_fresh
  | Fetch_stale of
      { reason : string
      ; consecutive_failures : int
      }

(* ---------- manual Yojson decoding ---------- *)

let string_field ?(default = "") json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default
;;

let bool_field ?(default = false) json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> b
  | _ -> default
;;

let int_field ?(default = 0) json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> i
  | `Intlit s -> (try int_of_string s with _ -> default)
  | _ -> default
;;

let entry_of_yojson (json : Yojson.Safe.t) : entry =
  let details =
    match Yojson.Safe.Util.member "details" json with
    | `Null -> None
    | other -> Some (Yojson.Safe.to_string other)
  in
  let level = string_field ~default:"INFO" json "level" in
  { seq = int_field json "seq"
  ; ts = string_field json "ts"
  ; level
  ; source = string_field ~default:"structured" json "source"
  ; module_ = string_field json "module"
  ; message = string_field json "message"
  ; details
  }
;;

let response_of_yojson (json : Yojson.Safe.t) : response =
  let entries =
    match Yojson.Safe.Util.member "entries" json with
    | `List lst -> List.map entry_of_yojson lst
    | _ -> []
  in
  { total = int_field json "total"
  ; entries
  ; fetch_status = Fetch_fresh
  }
;;

(* ---------- helpers ---------- *)

let fetch_status_label = function
  | Fetch_pending -> "fetch pending"
  | Fetch_fresh -> "fetch fresh"
  | Fetch_stale { consecutive_failures; _ } ->
    Printf.sprintf "fetch stale x%d" consecutive_failures
;;

let fetch_status_reason = function
  | Fetch_pending -> "waiting for first logs response"
  | Fetch_fresh -> "latest logs response parsed"
  | Fetch_stale { reason; _ } -> reason
;;

(** Level comparison — matches [Log.level_to_int] on the server. *)
let level_order = function
  | "DEBUG" -> 0
  | "INFO" -> 1
  | "WARN" -> 2
  | "ERROR" -> 3
  | _ -> 1
;;

(** Fixture for Phase 1a static render. Remove when fetch lands. *)
let fixture : response =
  { total = 3
  ; fetch_status = Fetch_pending
  ; entries =
      [ { seq = 3
        ; ts = "2026-04-19T17:12:03Z"
        ; level = "ERROR"
                    ; source = "structured"
              ; module_ = "Keeper"
        ; message = "heartbeat check failed: timeout after 30s"
        ; details = Some {|{"request_id":"req-9aa1","session_id":"sess-0012"}|}
        }
      ; { seq = 2
        ; ts = "2026-04-19T17:12:02Z"
        ; level = "WARN"
                    ; source = "structured"
              ; module_ = "Keeper"
        ; message = "retry scheduled in 5s"
        ; details = None
        }
      ; { seq = 1
        ; ts = "2026-04-19T17:12:00Z"
        ; level = "INFO"
                    ; source = "structured"
              ; module_ = "Server"
        ; message = "masc server started on :8935"
        ; details = None
        }
      ]
  }
;;
