(** Issuer-produced partition of logical context text, before message encoding
    or IPC serialization. No submitted-input or remote-retention claim. *)
type unattributed = Existing_prefix | Separator
type kind = Block of Prompt_block_id.t | Unattributed of unattributed
type subpartition = Not_applicable | Unavailable | Issued of Yojson.Safe.t
type span = private
  { kind : kind
  ; offset : int
  ; bytes : int
  ; sha256 : string
  ; subpartition : subpartition
  }
type receipt = private
  { bytes : int
  ; sha256 : string
  ; spans : span list
  }
type system_observation =
  | Current_norms of string
  | Active_goals of string
  | Direct_input_source of string
  | Goals_awaiting_proof of string
(** Only these issued observations can become System suffixes.
    [Current_norms] is the complete article set a
    {!Keeper_turn_system.Beside_text} names, under the
    {!Prompt_block_id.Constitution_amendments} id. It is the same text on
    every request of a turn, so Agent Core carries it here: as a User tail it
    was answered again after every tool result. An official client receives
    it as the block of that id instead; its projection sends a block the
    session already holds again only when the bytes change
    ({!Prompt_block_id.resent_when_held}).
    The other three come from the renderer.
    An official client reads the admitted operation source right behind the
    Goal snapshot on every request of its turn, from [admitted_source]. Agent
    Core does not issue it: the source rides the end context of the turn's
    first request, so the System does not change with the turn kind
    ({!Prompt_block_id.injected_on_post_tool_round} says what a later request
    of each lane carries). Agent Core
    keeps the current turn's proof state here so tool feedback remains the
    newest message. Official clients receive proof state as turn-scoped input
    instead. Completion Authority remains a context block. *)
val observation_block : system_observation -> Prompt_block_id.t * string

type proof_state = private { proof_text : string }
(** Evidence issued from the renderer's unique proof-state section. A raw
    named block is not evidence that the renderer issued that state. *)

val issue_proof_state : Keeper_context_layers.rendered -> proof_state option

type admitted_source = private { source_text : string }
(** The source of the admitted operation the turn serves, issued from the
    renderer's unique [Direct_input_source] section. A raw named block is not
    evidence that the renderer issued it. *)

val issue_admitted_source : Keeper_context_layers.rendered -> admitted_source option
(** [Some] when the layer split off by
    {!Keeper_context_layers.partition_layer} holds exactly one
    [Direct_input_source] section with text. *)

type system_prompt = private
  { base_text : string
  ; observations : system_observation list
  ; text : string
  ; partition : receipt
  }
(** One canonical issued System: the prior base/override followed by the
    exact issued observations, independently of the extra-context carrier.
    An official-client Resume may deliver a held observation in User; this
    issuer receipt is not that submitted packet. It is never a history row. *)
type t = private
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; receipt : receipt option
  ; dynamic_context_partition : Keeper_context_layers.rendered option
    (** The renderer's partition of the [Dynamic_context] block, kept only when
        its text is that block's text byte for byte. *)
  ; system_prompt : system_prompt option
    (** [None] means this generic extra assembly has no issued system value.
        Production request assembly also records an unchanged base without observations. *)
  ; proof_state : proof_state option
    (** The renderer-issued state this turn can carry across execution owners.
        It is independent of whether the current request puts it in System
        or in the official client's turn-scoped carrier. *)
  ; admitted_source : admitted_source option
    (** The renderer-issued source this turn carries across tool rounds and
        execution owners. An official client reads it in System on every
        request, also one that takes the turn over after an Agent Core round;
        Agent Core never puts it in System. *)
  }

val with_proof_state : proof_state option -> t -> t
val with_admitted_source : admitted_source option -> t -> t

val assemble :
  dynamic_context_partition:Keeper_context_layers.rendered option ->
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list -> t
(** Preserves [None] versus [Some ""], source order and every separator.
    [receipt=None] means no carrier exists, not a zero-byte carrier. *)

val split_block : Prompt_block_id.t -> t -> (t * string) option
(** [Some (rest, text)] when the carrier holds [block] exactly once: [text] is
    its exact bytes and [rest] is the same assembly issued again without it,
    with the same existing prefix, block order, separators, [Dynamic_context]
    partition and issued System. [rest] has no carrier when nothing else was
    in it. [None] when the block is absent, repeated, or there is no carrier. *)

val with_system_observations :
  base_text:string -> observations:system_observation list -> t -> t
(** Issue the supplied base or pre-existing override, appending an immutable
    list of uniquely named observations. Duplicate kinds are rejected. No text
    matching, store read or history mutation. An empty list leaves the exact
    base bytes unchanged. *)

val logical_blocks : t -> (Prompt_block_id.t * string) list
(** System observations followed by extra-context blocks, once each. The base instructions
    remain separately attributed by their existing producer. *)

val effective_system_prompt : base_text:string -> t -> string

val system_prompt_override : previous:string option -> t -> string option
(** Override only when the request carries an observation suffix. Otherwise preserve
    [None] versus [Some ""] and every byte of the prior override. *)

val system_prompt_receipt_to_json : system_prompt -> Yojson.Safe.t
(** Explicit canonical [system_prompt] source scope plus its exact raw UTF8
    partition. This is an issuer receipt, not a submitted-packet, remote-retention
    or encoded-wire claim. *)

val blocks_for_carrier : t -> string -> (Prompt_block_id.t * string) list option
(** Returns the issuer's blocks only for the exact carrier and when no prefix
    was supplied, including an empty prefix, and block IDs are unique.
    Otherwise the caller must retain
    the whole carrier. Separators alone do not prevent block delivery. *)

val dynamic_context_sections : t -> Keeper_context_layers.section list option
(** The [Dynamic_context] block as its renderer's sections, each with its exact
    text and division, in order: {!Keeper_context_layers.sections} of
    [dynamic_context_partition]. [None] when no partition was kept, when it has
    no section, or when two sections share a source, so a caller that cannot
    name every section apart keeps the block whole. *)

val split_outside_context : t -> string option * string option
(** Split assembled turn context into [(host_system_context, outside_context)]
    using {!Keeper_context_layers.author_of_layer} and an exhaustive
    classification of {!Prompt_block_id.t}. Untrusted outside/keeper-authored
    text is separated onto the [Outside_context] wire channel while host-owned
    state stays on [System_context]. *)

val has_split_request_context : t -> bool
(** Whether {!split_outside_context} produces at least one per-request context
    carrier ([System_context] and/or [Outside_context]) for AGENT_CORE. *)

val receipt_to_json : receipt -> Yojson.Safe.t
(** V2 adds a renderer-issued dynamic subpartition only when the exact block
    bytes match. Missing or stale renderer evidence is explicitly unavailable.
    Content-free raw UTF8 accounting, not serialized JSON byte accounting. *)
