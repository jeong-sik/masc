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
type system_prompt = private
  { base_text : string
  ; goal_text : string option
  ; text : string
  ; partition : receipt
  }
(** One issued effective system prompt: the prior base/override followed by
    the exact Goal observation. Its partition describes this physical carrier,
    independently of the extra-context carrier. It is never a history row. *)
type t = private
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; receipt : receipt option
  ; dynamic_context_partition : Keeper_context_layers.rendered option
    (** The renderer's partition of the [Dynamic_context] block, kept only when
        its text is that block's text byte for byte. *)
  ; system_prompt : system_prompt option
    (** [None] means this generic extra assembly has no issued system value.
        Production request assembly also records an unchanged base without a Goal. *)
  }

val assemble :
  dynamic_context_partition:Keeper_context_layers.rendered option ->
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list -> t
(** Preserves [None] versus [Some ""], source order and every separator.
    [receipt=None] means no carrier exists, not a zero-byte carrier. *)

val with_goal_system_prompt : base_text:string -> goal_text:string option -> t -> t
(** Issue the supplied base or pre-existing override, appending an immutable
    Goal observation only when present. No text matching, store read or history
    mutation. [None] leaves the exact base bytes unchanged. *)

val logical_blocks : t -> (Prompt_block_id.t * string) list
(** Goal followed by extra-context blocks, once each. The base instructions
    remain separately attributed by their existing producer. *)

val effective_system_prompt : base_text:string -> t -> string

val system_prompt_override : previous:string option -> t -> string option
(** Override only when the request carries a Goal suffix. Otherwise preserve
    [None] versus [Some ""] and every byte of the prior override. *)

val system_prompt_receipt_to_json : system_prompt -> Yojson.Safe.t
(** Explicit [system_prompt] carrier plus its exact raw UTF8 partition. This
    is an issuer receipt, not a remote-retention or encoded-wire claim. *)

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
