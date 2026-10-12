(** Issuer-produced partition of logical context text, before message encoding
    or IPC serialization. No submitted-input or remote-retention claim. *)
type unattributed = Existing_prefix | Separator
type kind = Block of Prompt_block_id.t | Unattributed of unattributed
type span = private
  { kind : kind
  ; offset : int
  ; bytes : int
  ; sha256 : string
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
  }

val assemble :
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list -> t
(** Preserves [None] versus [Some ""], source order and every separator.
    [receipt=None] means no carrier exists, not a zero-byte carrier. *)

val blocks_for_carrier : t -> string -> (Prompt_block_id.t * string) list option
(** Returns the issuer's blocks only for the exact carrier and when no prefix
    was supplied, including an empty prefix, and block IDs are unique.
    Otherwise the caller must retain
    the whole carrier. Separators alone do not prevent block delivery. *)

val receipt_to_json : receipt -> Yojson.Safe.t
(** Content-free raw UTF8 byte accounting. Not serialized JSON byte accounting. *)
