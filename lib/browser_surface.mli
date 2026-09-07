(** Read-only browser page observations from the selected source. *)
type source = Live | Automation
type request = { source : source; tab_id : int option }
val parse_request : Yojson.Safe.t -> (request, string) result
val read : request -> (Yojson.Safe.t, string) result
val decode_answer : Browser_lane.answer -> (Yojson.Safe.t, string) result
