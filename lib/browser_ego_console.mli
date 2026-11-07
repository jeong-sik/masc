(** What an ego Page's document wrote to its console and the errors it did not
    catch, read in one step that turns ego's console hiding off and back on
    (RFC-browser-ego-cdp-capabilities §3.3 read_console). *)

val entries_limit : int
val text_bytes_limit : int

val browser_kept_entries : int
(** How many console entries of a document the browser keeps before it drops
    the oldest. *)

val script : answer_units:int -> string
(** Declares [mascConsoleRead(page, reason)], which answers the step's emit
    object. It needs {!Browser_ego_page_events.script} before it, and keeps
    the entries of its answer within [answer_units] UTF-16 units of JSON. *)

type kind = Console | Javascript
type entry = { kind : kind; level : string; text : string; text_cut : bool; timestamp : int }
type hiding = Restored of { off_ms : int } | Left_off of { off_ms : int; error : string }
type read = { entries : entry list; dropped : int; malformed : int; last_malformed : string option; hiding : hiding }

val of_json : Yojson.Safe.t -> (read, string) result
(** Refuses an answer of another shape, including a text past
    {!text_bytes_limit} bytes or not UTF-8. *)

val receipt : tab:int -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The answer for one tab, rebuilt from [of_json]. Hiding left off carries
    a note that says so. *)
