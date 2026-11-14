(** Complete immutable Task documents. Preparation is presentation only. *)
val status_label : ko:bool -> Masc_domain.task_status -> string
(** Shared localized label for the list, preview and current Task document. *)
val status_tag_label : ko:bool -> Masc_domain.Task_status_tag.t -> string
(** The same label for a status without its payload, for a count of the
    tasks in that status (the Metrics task rows). *)
type goals = Unread | Unavailable of string | Membership of string list | Canonical of string option
type part = Body | History
type input
val body : ko:bool -> cols:int -> goals:goals -> Masc_domain.task -> input
val history : ko:bool -> cols:int -> Masc.Tui_decode.task_history_event list -> input
val equal_input : input -> input -> bool
(** Same width and immutable payload object; comparison never scans Task text
    or event content. Language and Goal observations are compared independently. *)
val part : input -> part
val columns : input -> int
val is_korean : input -> bool
val prepare : input -> string list
(** Wrap and sanitize all content once on the CPU worker. No truncation. A
    history note that is a JSON object or array is drawn as the chat draws a
    served document, in colour; every other note keeps the one colour. A blank
    line inside a note is a blank row; blank lines at either end of a note are
    dropped. *)
val history_heading_rows : ko:bool -> width:int -> string list
(** The History section's heading, wrapped to [width] and drawn in the style
    of the Body's section headings. The rows carry their own style: a caller
    must not hand them to a wrapper that sanitises text. *)
val history_status_lines : ko:bool -> width:int -> view:Masc.Tui_decode_task_inspection.history Masc_tui_fetched.view -> in_flight:bool -> continuing:bool -> string list
(** Current read/pending/failure metadata only; contains no event-body work.
    The section heading is {!history_heading_rows}. *)
