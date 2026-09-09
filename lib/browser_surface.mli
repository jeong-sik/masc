(** Read-only browser page observations from the selected source. *)
type source = Live | Automation
type request = { source : source; tab_id : int option; client_id : Browser_lane.client_id option }
val parse_request : Yojson.Safe.t -> (request, string) result
val read : request -> (Yojson.Safe.t, string) result
val decode_answer : Browser_lane.answer -> (Yojson.Safe.t, string) result

val parse_capture_request : Yojson.Safe.t -> (request, string) result
(** Capture requires an explicit tab ID; it never falls back to an active tab. *)
val capture : request -> (Yojson.Safe.t, string) result
(** Viewport PNG as bare base64, source/tab identity, URL/title and elapsed time. *)

val parse_client_id : Yojson.Safe.t -> (Browser_lane.client_id option, string) result
val resolved_target : request -> (Browser_lane.target, string) result
val client_id_json : Browser_lane.target -> Yojson.Safe.t
