(** Keeper_model_input_ledger — what one runtime's requests carried, in the
    provider's own token count (RFC keeper-context-window-in-tokens §10.3).

    The ledger never estimates. It records, per provider call, the carried
    atom range the projection chose and the [input_tokens] the provider
    reported for that request. Two consecutive requests under the same
    prefix, with no atom removed in between, differ by exactly the atoms
    appended between them plus whatever the per-request tail changed, so
    that difference is written down as the token count of the appended
    block. A request whose usage is missing leaves its atoms unmeasured
    until the next usage arrives; the difference then covers every atom
    appended since the last measured request, as one block.

    Anything that breaks the comparison restarts the ledger from the request
    at hand: a different prefix (system prompt or tool schemas), a history
    that shrank (a new session), a front that moved back, or a front that
    fell inside a block. A front move over measured blocks only subtracts
    them. A front move over a block of unknown size (the cold-start block)
    keeps the measured blocks and leaves the total unknown until the next
    usage; the block appended in that same request can then never be
    measured, and when it is evicted in turn the same happens once more.
    The chain ends at the first eviction whose request appends nothing.

    A difference that comes out negative (the tail shrank by more than the
    new atoms added) is reported and not written into any block. A usage
    reporting zero input tokens is not a measurement; {!usage_of_counts}
    turns it into [None].

    The table is process memory keyed by keeper and runtime. Token counts
    are the provider's, so the same atoms carried on another runtime are a
    separate ledger. *)

(** One request as the projection handed it to the provider. *)
type request =
  { prefix_digest : string
        (** SHA-256 of the system prompt and tool schemas: the fixed prefix F. *)
  ; first_atom : int  (** Index of the oldest carried atom in the durable history. *)
  ; atom_count : int  (** Atoms the durable history held when this request was built. *)
  ; tail_bytes : int
        (** Bytes of the per-request tail (extra system context and other
            pinned messages), measured with the request encoder. *)
  }

type usage =
  { input_tokens : int  (** The provider's inclusive prompt total. *)
  ; cache_read_input_tokens : int
  }

type block =
  { block_first_atom : int
  ; block_end_atom : int  (** Exclusive. *)
  ; tokens : int option
        (** Provider-counted tokens of the atoms in this range, including the
            change of the per-request tail between the two requests that
            bracket it. [None] while no usage has bracketed the range. *)
  }

type t =
  { prefix_digest : string
  ; total_tokens : int option
        (** [input_tokens] of the last measured request: prefix, carried atoms
            and tail together. [None] after a front move removed atoms whose
            tokens were unknown, until the next usage. *)
  ; measured_end_atom : int option
        (** [atom_count] of the request [total_tokens] describes. *)
  ; blocks : block list  (** Oldest first, contiguous over the carried range. *)
  ; last : request
  ; last_usage : usage option
  }

type event =
  | Started  (** First request seen for this keeper and runtime. *)
  | Appended of
      { new_atoms : int
      ; measured : bool  (** Whether this usage assigned tokens to a block. *)
      }
  | Repeated  (** Same carried range as the previous request. *)
  | Front_moved of
      { evicted_atoms : int
      ; evicted_tokens : int option
            (** Known when every removed block was measured; then measurement
                continues across the move. Unknown when a block of unknown
                size left (the cold-start block, for one): the blocks that
                stayed keep their counts and the total is unknown until the
                next usage. *)
      }
  | Front_cut_through_block of { evicted_atoms : int }
      (** The front fell inside a block; restarted from this request. *)
  | Front_widened
      (** The front moved back toward older atoms, as it does on the request
          after a newest-atom-only one; restarted from this request. *)
  | Prefix_changed  (** System prompt or tool schemas differ; restarted. *)
  | History_reset  (** The history shrank; restarted. *)

type observation =
  { ledger : t
  ; event : event
  ; delta_tokens : int option
        (** [input_tokens] minus the previous measured total, corrected for
            evicted blocks, when both were known. *)
  ; tail_delta_bytes : int  (** Tail bytes of this request minus the previous. *)
  }

val observe : t option -> request -> usage option -> observation
(** Pure step. [None] starts a ledger from the request. *)

val usage_of_counts : input_tokens:int -> cache_read_input_tokens:int -> usage option
(** [None] unless [input_tokens] is positive: a zero-filled usage is the
    shape of a response that reported nothing. *)

val known_tokens : t -> int
(** Sum of the measured blocks' tokens. *)

val unmeasured_atoms : t -> int
(** Carried atoms not covered by a measured block. *)

val event_to_string : event -> string

val to_json : t -> Yojson.Safe.t
(** Counts and totals only; the block list is {!blocks_to_json}. *)

val blocks_to_json : t -> Yojson.Safe.t
val observation_to_json : observation -> Yojson.Safe.t

val prefix_digest : system_prompt:string -> tools:Agent_core.Tool.t list -> string
(** SHA-256 hex over the system prompt and the tool schemas in declaration
    order, the same JSON the request carries. *)

(** Process-wide table, one ledger per keeper and runtime. *)
module Table : sig
  val observe
    :  keeper_name:string
    -> runtime_id:string
    -> request:request
    -> usage:usage option
    -> observation

  val lookup : keeper_name:string -> runtime_id:string -> t option

  module For_testing : sig
    val reset : unit -> unit
  end
end
