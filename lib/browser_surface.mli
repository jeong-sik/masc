(** Read-only browser page observations from the selected source. *)
type source = Live | Automation
type request = { source : source; tab_id : int option; client_id : Browser_lane.client_id option }
val parse_request : Yojson.Safe.t -> (request, string) result
type tab = { id : int; title : string; url : string; active : bool }

(** Which tab a read answers for. [None_active] means no tab was requested
    and none is active, so the answer carries [page = null] and reads nothing. *)
type selection = Requested of tab | Active of tab | None_active
val select : tab_id:int option -> tab list -> (selection, string) result
val read : request -> (Yojson.Safe.t, string) result
(** Tabs, [selection] as "requested" | "active" | "none_active", the page of the
    selected tab or null, source, clientId and elapsed_ms. *)

val decode_answer : Browser_lane.answer -> (Yojson.Safe.t, string) result

val parse_capture_request : Yojson.Safe.t -> (request, string) result
(** Capture requires an explicit tab ID; it never falls back to an active tab. *)
val capture : request -> (Yojson.Safe.t, string) result
(** Viewport PNG as bare base64, source/tab identity, URL/title and elapsed time. *)

val parse_client_id : Yojson.Safe.t -> (Browser_lane.client_id option, string) result
val resolved_target : request -> (Browser_lane.target, Browser_lane.selection_error) result
val client_id_json : Browser_lane.target -> Yojson.Safe.t
