(** Invocation-local input/response evidence. This does not own a receiver,
    accept another command, change a turn result, or keep background work alive. *)

type ticket = private
  { receiver_generation : string; session_id : string; client_uuid : string }

type group = private { primary : string; consumed : string list }
(** Provider order is preserved. Membership, not primary equality, proves that
    this ticket was consumed. Unknown members are not new host tickets. *)

type rejection =
  | Duplicate_field
  | Invalid_primary
  | Invalid_group
  | Group_without_primary
  | Primary_not_in_group
  | Duplicate_member
  | Group_exceeds_provider_limit
  | Missing_frame_uuid
  | Foreign_session
  | Conflicting_frame_replay
  | Ambiguous_response

type command_witness = private { group : group; stamp_uuid : string }
(** Exact root stamp that witnessed this host's typed SDK command. The group is
    the complete observed snapshot, not a guess about later unstamped folds. *)

type attribution =
  | Unattributed
  | Explicit of group
  | Inherited of group
  | Command_inherited of command_witness
  | Rejected of rejection

val decode : (string * Yojson.Safe.t) list -> attribution
(** Optional SDK user_message_uuid(s). A present malformed plural never falls
    back to singular. Identifiers remain opaque, byte-identical strings. *)

type outcome = Provider_success | Provider_error

type phase = Prepared | Written | Write_unknown | Consumed | Settled of outcome
(** [Settled] is validated provider-result evidence. Subsequent host callbacks,
    model/body validation or delivery can still fail. [Consumed] does not prove
    a model request was sent or that the user saw any output. *)

type frame =
  | Partial_start of { uuid : string option; message_id : string }
  | Partial_fragment of { uuid : string option }
  | Partial_stop of { uuid : string option }
  | Assistant of { uuid : string option; message_id : string option }
  | Result of { uuid : string option; outcome : outcome option }
(** [outcome=None] is a result whose terminal outcome could not be validated.
    It may report attribution but cannot settle the ticket. *)

type observation = private
  { ticket : ticket; phase : phase; frame : frame option; attribution : attribution }
(** [phase] is accumulated evidence about [ticket], not ownership of this
    particular frame. [frame=None] denotes only a host write boundary. *)

type t

val create : receiver_generation:string -> session_id:string -> client_uuid:string -> t
(** The runtime mints both UUIDs once for its sole typed (non-meta) host input.
    The helper is pure with respect to IO; it is not a multi-command receiver. *)
val ticket : t -> ticket
val user_message : t -> content:Yojson.Safe.t list -> Yojson.Safe.t
(** Outer SDK user envelope, with the host UUID. Content blocks are passed
    through unchanged; the existing SDK input session sentinel is preserved. *)
val prepared : t -> observation
val written : t -> observation
val write_unknown : t -> observation
val unowned_response_start : t -> message_id:string -> unit
(** A parsed SDK start without root ownership retires the inheritance cursor.
    It cannot consume the host ticket or establish a root response binding. *)
val observe : t -> session_id:string -> frame:frame ->
  (string * Yojson.Safe.t) list -> observation option
(** Called for validated root frames only. Exact duplicate metadata emits no
    new observation. A replayed start across another/closed occurrence retires
    inheritance instead of selecting its old owner. An exact historical stop
    replay leaves the current binding intact: the content parser does not move
    its cursor on that event. Immediate same-occurrence start replay preserves
    its binding. Fresh or rejected stop boundaries still retire inheritance.
    Distinct message_start frames create distinct occurrences even
    if their provider string ID is reused. Response-based inheritance requires
    that witnessed occurrence; a complete envelope's ID must be unambiguous
    for that proof route. After a confirmed write and fresh root stamp with this input
    as primary, the typed SDK command also owns later unstamped root responses
    across model IDs/stops: [Command_inherited] preserves that distinct proof.
    A reused model ID blocks response-occurrence selection but does not block
    this separately available command proof for a fresh assistant envelope.
    Foreign-primary membership proves consumption only, never that command.
    Contradictions suspend command inheritance; exact replay cannot reseed it.
    Invalid/stale response scope cannot be hidden by the command proof route.
    A fresh explicit stamp can update an ongoing response's group.
    Any root result ends command inheritance. Results NEVER inherit. A rejected stamp invalidates subsequent inheritance
    for that occurrence until another explicit stamp, without retracting facts.
    All state retires with this invocation, with no time-based eviction. *)
