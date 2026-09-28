type client = Codex | Claude | Antigravity | Muse
type provider = { id : string; label : string; client : client }
type model = { id : string; label : string; context : int option; tools : bool option }
type phase = Loading | Providers | Logging | Models | Documented_context of model | Saving | Finished | Failed
type recovery = Login_status | Refresh_configuration
type email_gap = Login_file_unreadable | Login_file_unrecognized | Email_not_reported | Email_not_displayable
type account_email = Email of string | Not_read of email_gap
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable cursor : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option; mutable recovery : recovery;
  mutable account_emails : (string * account_email) list;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved | Refresh_retry | Start of bool | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model | Close | Nothing
val create : string -> t
val begin_attempt : t -> provider -> existing:bool -> string option
(** Capture the requested account, clear the previous live session identity and
    reset login input state before the next process is launched. *)
val key : t -> string -> action
val paste : t -> string -> unit
(** Preserve printable UTF-8 and spaces; remove at most one trailing CR, LF or
    CRLF. Reject other multiline/control input without changing the draft. *)
val inventory : t -> Yojson.Safe.t -> (unit, string) result
val save_failed : t -> model -> string -> unit
val refresh_retry : t -> (Yojson.Safe.t, string) result -> unit
(** Refresh configuration revision and selection after an unsuccessful save,
    retaining the account and chosen model for an explicit retry. *)
val refresh_saved : t -> (Yojson.Safe.t, string) result -> unit
val input_response : sequence:int -> t -> (Yojson.Safe.t, string) result -> unit
val models : t -> Yojson.Safe.t -> (unit, string) result
val prepared : t -> model -> Yojson.Safe.t -> (unit, string) result
val receipt : t -> Yojson.Safe.t -> (bool, string) result
val event : generation:int -> t -> event -> action
val source : t -> Yojson.Safe.t
val save_body : t -> model -> Yojson.Safe.t
type row =
  | Text of string  (** Written by this pane or the server: drawn as plain text. *)
  | Terminal of Masc_tui_sgr_text.line
      (** What the official client printed during login, with the colours it
          chose. *)
val lines : t -> row list
val row_text : row -> string
(** The row's characters without colour. *)
val visible_lines : height:int -> t -> row list
val hints : t -> string
val decoder : integration_id:string -> (event -> unit) -> (string -> unit) * (unit -> bool)
