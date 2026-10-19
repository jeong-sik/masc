(** Complete immutable Task documents. Preparation is presentation only. *)
type goals = Unread | Unavailable of string | Membership of string list | Canonical of string option
type part = Body | History
type input
val body : cols:int -> goals:goals -> Masc_domain.task -> input
val history : cols:int -> Masc.Tui_decode.task_history_event list -> input
val equal_input : input -> input -> bool
(** Same width and immutable payload object; comparison never scans Task text
    or event content. Goal observations are compared independently. *)
val part : input -> part
val columns : input -> int
val prepare : input -> string list
(** Wrap and sanitize all content once on the CPU worker. No truncation. *)
val history_status_lines : width:int -> view:Masc.Tui_decode_task_inspection.history Masc_tui_fetched.view -> in_flight:bool -> string list
(** Current read/pending/failure metadata only; contains no event-body work. *)
