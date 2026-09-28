type client = Codex | Claude | Antigravity | Muse
type provider = { id : string; label : string; client : client }
type model = { id : string; label : string; context : int option; tools : bool option }

(** What removing an account changes, as the setup API's removal preview
    lists it. *)
type removal_change =
  | Removed_table of string
  | Left_lane of { lane : string; runtime : string }
  | Left_exact_lane of { lane : string; runtime : string }
  | Left_vision of string
  | Unassigned of { keeper : string; runtime : string }
      (** The keeper routes to the default once the account is gone. *)
type removal =
  | Removable of { changes : removal_change list; login_store : string option }
  | Unremovable of string  (** Why the server will not remove it. *)
type phase = Loading | Providers | Logging | Models | Documented_context of model | Saving | Finished | Failed
  | Removal of { provider : provider; revision : string; removal : removal }
      (** [D] on a provider: what removing it changes, read at [revision]. *)
type recovery = Login_status | Refresh_configuration
type email_gap = Login_file_unreadable | Login_file_unrecognized | Email_not_reported | Email_not_displayable
  | Environment_credential
type account_email = Email of string | Not_read of email_gap
  | Unrecognized  (* the server's row for this account had a shape this TUI does not know *)
type account_emails =
  | Email_rows of { rows : (string * account_email) list; unattributed : int }
      (* [unattributed]: rows naming no listed integration, or no integration at all *)
  | Email_list_unrecognized  (* the inventory carried no readable email list *)
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable cursor : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option; mutable recovery : recovery;
  mutable account_emails : account_emails;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved | Refresh_retry | Start of bool | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model | Close | Nothing
  | Preview_removal of { provider : provider; refused : string option }
      (** Read what removing [provider] changes. [refused] is why the server
          declined the removal just asked for, shown above the fresh preview. *)
  | Remove of { provider : provider; revision : string; login_store : string option }
      (** Remove [provider] while runtime.toml is still [revision]. *)
  | Refresh_removed of string
      (** Read the list again and show this notice over it. *)
val create : string -> t
val begin_attempt : t -> provider -> existing:bool -> string option
(** Capture the requested account, clear the previous live session identity and
    reset login input state before the next process is launched. *)
val key : t -> string -> action
val paste : t -> string -> unit
(** Preserve printable UTF-8 and spaces; remove at most one trailing CR, LF or
    CRLF. Reject other multiline/control input without changing the draft. *)
val inventory : t -> Yojson.Safe.t -> (unit, string) result
val emails_of_document : Yojson.Safe.t -> ((string * string) list * int, string) result
(** The [account_emails] of [GET /api/v1/setup/account-emails], for a surface
    that draws only emails: the [(integration id, email)] rows that were read,
    and how many rows this TUI could not read (no id, an id listed twice, or a
    shape it does not know). A row that says why no email was read is neither.
    [Error] when the document carries no readable list. *)
val removal_preview : t -> provider -> refused:string option -> Yojson.Safe.t -> (unit, string) result
(** The setup API's removal preview for [provider]: the changes, or why it
    cannot be removed. [Error] when the answer is for another provider or does
    not read. *)
val removed_notice : provider -> string option -> string
(** What the list says once [provider] is removed, with the login store left
    on disk. *)
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
val visible_lines : height:int -> width:int -> t -> row list
(** The rows that fit [height], the notice wrapped at [width] cells so a
    server's reason is read whole. *)
val hints : t -> string
val decoder : integration_id:string -> (event -> unit) -> (string -> unit) * (unit -> bool)
