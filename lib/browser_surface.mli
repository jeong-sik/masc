(** Read-only Browser/WebApp view. Slack is selected by parsed URL, never by
    page-text guessing. Every displayed page is a fresh browser observation. *)
type app = Browser | Slack
type source = Live | Automation
type request = { source : source; app : app; tab_id : int option }
val parse_request : Yojson.Safe.t -> (request, string) result
val read : request -> (Yojson.Safe.t, string) result
val is_slack_url : string -> bool
val decode_answer : Browser_lane.answer -> (Yojson.Safe.t, string) result
