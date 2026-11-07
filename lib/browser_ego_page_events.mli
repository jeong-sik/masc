(** One drain of an ego Page's event buffer for every step that reads it,
    and the tab network log that drain keeps (RFC-browser-ego-cdp-capabilities
    §3.4). *)

val requests_limit : int
val path_bytes_limit : int
val header_names_limit : int
val redacted_value : string

val ego_buffer_events : int
(** How many events ego lite keeps for a Page before it drops the oldest. *)

val script : string
(** Declares [mascPageEvents(page)], which drains the Page's buffer and
    answers every event but the Network ones, those kept from earlier drains
    first, and [mascNetworkLog(page)], which drains it and answers the tab's
    log. Every step script that reads a Page's events includes this text and
    calls one of the two, never [page.events()]. *)

type names = { listed : string list; total : int }
type outcome =
  | Pending
  | Responded of { status : int; mime_type : string; response_headers : names }
  | Completed of { status : int; mime_type : string; bytes_received : int; response_headers : names }
  | Failed of string
type request = { method_ : string; url : string; url_cut : bool; timestamp : int; request_headers : names; outcome : outcome }
type log = { requests : request list; dropped : int; malformed : int; last_malformed : string option; full_buffer_reads : int }

val of_json : Yojson.Safe.t -> (log, string) result
(** Refuses an answer of another shape, including an address that keeps a
    user, a fragment or a query value. *)

val receipt : tab:int -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The answer for one tab, rebuilt from [of_json]. *)
