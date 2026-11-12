(** What a goal's detail has to say under its header.

    The list already draws the judge's verdict and its reason on the line
    under the cursor -- the reason being, as that code says, the only thing
    that says what to do next. The detail drew neither, so opening a goal
    showed less than the row it was opened from, and the two fields the
    surface decodes for it went nowhere.

    This is the block that fills the gap, and the rows it produces are what
    the detail's scroll moves through. *)

type tone =
  | Proven
  | Refused
  | Waiting
  | Unreadable
  | Note
  | Quiet
  | Plain
  | Heading
      (** A section's own title. It is drawn in the heading style the other
          detail screens use (info colour, bold), so a long detail has
          landmarks to scroll between; the rows under it keep their tones. *)

type line =
  { tone : tone
  ; text : string
  }

module Tui_decode = Masc.Tui_decode

(** The metadata projection of one submitted original, as the confirmation
    read carries it: identity and size without contents, and the file digest
    for a binary original. A kind this build does not know stays visible as
    [Original_unknown]. *)
type submitted_original =
  | Original_collaboration of { reference : string; bytes : int }
  | Original_note of { bytes : int }
  | Original_artifact of { reference : string; bytes : int; truncated : bool }
  | Original_binary of { reference : string; bytes : int; sha256 : string; format : string }
  | Original_unreadable of { reference : string option; reason : string }
  | Original_unknown of string

type confirmation_workspace = {
  base_path : Tui_decode.Canonical_path.t;
  masc_root : Tui_decode.Canonical_path.t;
}

val confirmation_workspace_of_identity : Tui_decode.server_identity -> confirmation_workspace
val same_confirmation_workspace : confirmation_workspace -> confirmation_workspace -> bool

type confirmation = {
  goal_id : string;
  phase : Goal_phase.t;
  verdict : Goal_verification.verdict;
  recorded_confirmation : Goal_verification.confirmation option;
  submitted : submitted_original list;
  workspace : confirmation_workspace;
  inspection_operator_id : string;
  runtime_instance_id : string;
  credential_headers : (string * string) list;
  credential_owner : unit ref;
}

type receipt_authority = {
  ra_workspace : confirmation_workspace;
  ra_operator_id : string;
  ra_runtime_instance_id : string;
  ra_credential_owner : unit ref;
}

val confirmation_receipt_authority : confirmation -> receipt_authority

type confirmation_read_error =
  | Read_failed of unit ref option * string
  | Read_http_error of unit ref * int
  | Server_changed of unit ref

type confirmation_read = (string, confirmation, confirmation_read_error) Masc_tui_fetched.source

type confirmation_state =
  | Inspecting of confirmation_read
  | Submitting of string * confirmation_read

val confirmation_read_error_message : ko:bool -> credential_is_current:(unit ref -> bool) -> confirmation_read_error -> string

val suspend_confirmation_read : confirmation_read -> confirmation_read
(** Withdraw a proof's authority while retaining its key for a later reread. *)
val confirmation_view_for : confirmation_read -> goal_id:string -> (confirmation, confirmation_read_error) Masc_tui_fetched.observation
(** A revalidation hides the previous proof as soon as its read starts. *)

val decode_confirmation : goal_id:string -> workspace:confirmation_workspace -> runtime_instance_id:string -> credential_headers:(string * string) list -> credential_owner:unit ref -> Yojson.Safe.t -> (confirmation, string) result
val confirmation_body : confirmation -> Yojson.Safe.t
val same_confirmation_binding : confirmation -> confirmation -> bool
val same_recorded_confirmation : confirmation -> confirmation -> bool
val receipt_authority_current : credential_current:bool -> current_instance:string option -> current_confirmation:confirmation option -> receipt:receipt_authority -> bool
val receipt_outcome_text : ko:bool -> current:bool -> (string, string) result -> string
val confirmation_lines : width:int -> ko:bool -> confirmation -> line list
(** The proof displayed before the operator confirms, in layers: the
    instruction, the goal's promise, the binding, a candidate coverage
    notice, and the evidence. Its binding is retained for the POST, so a
    newer proof cannot silently replace it. Confirmation requires a
    presented reader frame containing the block's final evidence row; this
    does not establish that each earlier row was read. *)

val body :
  ko:bool -> width:int -> Tui_decode.goal_proof -> string option -> line list
(** The verdict, its reason, and the keeper's own note, wrapped to [width].

    An idle ledger with no note still says so: an empty block would read as a
    goal nobody has looked at, which is the same picture a goal whose verdict
    failed to decode would draw. *)

val unreconciled_heading : ko:bool -> Goal_reconcile_step.t -> string
(** Which verifier step could not settle the goal, as the row's headline. *)

val verifying_next_step : ko:bool -> can_retry:bool -> Tui_decode.verifier_unreconciled option -> tone * string
(** The retry is offered only while the displayed proof has a readable binding.
    Its response may report an unresolved original instead of a new review. *)

val unreconciled_lines :
  ko:bool -> width:int -> Tui_decode.verifier_unreconciled -> line list
(** The headline and the store's reason, wrapped and sanitized like a
    verdict, for a Verifying goal the latest verifier scan could not
    settle. *)

val short_ts : string -> string
(** "2026-07-28T03:57:38Z" -> "07-28 03:57"; anything shorter is shown as-is
    rather than guessed at. Shared with the task-history rows. *)

val split_embedded_json : string -> (string * string * string) option
(** A whole JSON value hiding inside a prose summary, split out: answers
    (text before the value, the value laid out one member per line, text
    after it), or [None] when no brace-to-brace substring parses. Yojson
    decides what is JSON; the layout inserts whitespace into the validated
    original and copies every other byte verbatim, so number literals keep
    their spelling ([1E400] stays [1E400], not "Infinity") and a string
    holding JSON-looking text stays a quoted string. Shared with the keeper
    detail's current-failure block, which reads the same wire summaries. *)

val moment_text : now:float -> string -> string
(** A moment the wire spells as ISO-8601 text, where it has a line or a clause
    to itself: the clock alone today, month and day first inside this year,
    the year too in another one, all in the operator's zone
    ({!Masc_tui_value.Instant.detail_text}). The Goal screens printed the wire
    text itself, so "Created" read [2026-11-11T10:39:49Z] -- UTC, nine hours
    off every moment the other screens draw, with only a trailing Z to say
    so. Text that
    does not parse is returned as it arrived. *)

val timeline_unavailability_detail : Tui_decode.goal_timeline_unavailability -> string
(** Preserve the typed source failure's cause at the history read boundary. *)

val timeline :
  ko:bool -> now:float -> width:int ->
  goal_id:string ->
  (string, Tui_decode.goal_timeline_event list) Masc_tui_fetched.t ->
  line list
(** The goal's merged event timeline, appended after [body] so it rides the
    same scroll. Loaded lazily on detail entry; every non-ready state (still
    loading, store unavailable, load failed, stale answer for another goal)
    says what it is instead of rendering as an empty history. Refresh failures
    retain the last observed rows with their stale reason; they do not certify
    the goal's current work or turn a source-unavailable result into success.
    Each row's stamp is drawn in the operator's time zone; [now] decides how
    much of its date the row still needs. *)

val criterion_review_lines :
  width:int -> ko:bool -> Tui_decode.goal_criterion_review -> line list
(** Creation-criterion review observation, including the exact request and
    revision binding. It never changes completion proof or confirmation. *)
