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
    [Current_norms] is the complete article set of
    {!Keeper_turn_system.t.current_norms}, under the
    {!Prompt_block_id.Constitution_amendments} id. It is the same text on
    every request of a turn, so Agent Core carries it here: as a User tail it
    was answered again after every tool result. Official clients receive it
    as a context block, because their System outlives the turn.
    The other three come from the renderer.
    The admitted operation source follows the Goal snapshot and is held across
    tool rounds independently of the remaining dynamic context. Agent Core
    keeps the current turn's proof state here so tool feedback remains the
    newest message. Official clients receive proof state as turn-scoped input
    instead. Completion Authority remains a context block. *)
val observation_block : system_observation -> Prompt_block_id.t * string

type proof_state = private { proof_text : string }
(** Evidence issued from the renderer's unique proof-state section. A raw
    named block is not evidence that the renderer issued that state. *)

val issue_proof_state : Keeper_context_layers.rendered -> proof_state option

type system_prompt = private
  { base_text : string
  ; observations : system_observation list
  ; text : string
  ; partition : receipt
  }
(** One canonical issued System: the prior base/override followed by exact
    renderer-issued observations, independently of the extra-context carrier.
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
  }

val with_proof_state : proof_state option -> t -> t

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

val receipt_to_json : receipt -> Yojson.Safe.t
(** V2 adds a renderer-issued dynamic subpartition only when the exact block
    bytes match. Missing or stale renderer evidence is explicitly unavailable.
    Content-free raw UTF8 accounting, not serialized JSON byte accounting. *)
