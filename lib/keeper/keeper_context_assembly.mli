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
type t = private
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; receipt : receipt option
  ; dynamic_context_partition : Keeper_context_layers.rendered option
    (** The renderer's partition of the [Dynamic_context] block, kept only when
        its text is that block's text byte for byte. *)
  }

val assemble :
  dynamic_context_partition:Keeper_context_layers.rendered option ->
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list -> t
(** Preserves [None] versus [Some ""], source order and every separator.
    [receipt=None] means no carrier exists, not a zero-byte carrier. *)

val blocks_for_carrier : t -> string -> (Prompt_block_id.t * string) list option
(** Returns the issuer's blocks only for the exact carrier and when no prefix
    was supplied, including an empty prefix, and block IDs are unique.
    Otherwise the caller must retain
    the whole carrier. Separators alone do not prevent block delivery. *)

val dynamic_context_sections : t -> (Keeper_context_layers.source * string) list option
(** The [Dynamic_context] block as its renderer's sections, each with its exact
    text, in order: {!Keeper_context_layers.sections} of
    [dynamic_context_partition]. [None] when no partition was kept, when it has
    no section, or when two sections share a source, so a caller that cannot
    name every section apart keeps the block whole. *)

val receipt_to_json : receipt -> Yojson.Safe.t
(** V2 adds a renderer-issued dynamic subpartition only when the exact block
    bytes match. Missing or stale renderer evidence is explicitly unavailable.
    Content-free raw UTF8 accounting, not serialized JSON byte accounting. *)
