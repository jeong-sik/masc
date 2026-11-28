(** Keeper_model_input_ledger — what one runtime's requests carried, in the
    provider's own token count (RFC keeper-context-window-in-tokens §10.3).

    The ledger never estimates. It records, per provider call, the carried
    atom range the projection chose and the [input_tokens] the provider
    reported for that request. A usage is a sample only when its request
    carried no turn context: the per-turn [system context] message (recall,
    briefing, clock) rides the turn's first request and not the rounds after
    it, so its tokens belong to no atom. Two consecutive samples under the
    same prefix, with no atom removed in between, differ by exactly the
    atoms appended between them, so that difference is written down as the
    token count of the appended block. A request whose usage is missing or
    is not a sample leaves its atoms unmeasured until the next sample; the
    difference then covers every atom appended since the last sample, as
    one block. The atoms around a turn boundary are measured that way, by
    the first post-tool round of the next turn.

    The same turn boundary moves the demotion boundary: the previous turn's
    tool results go out as markers from then on, so the blocks that hold
    them weigh less than they were measured at. When a sample's demotion
    boundary differs from the one the total was measured under, the blocks
    from the lower boundary on and the atoms appended since become one
    block, whose tokens are the reformed blocks' old counts plus the
    difference. The difference is exactly the appended atoms plus the
    reformed atoms' change, so that sum is what they weigh now; it is unknown
    when a reformed block was never measured.

    Anything that breaks the comparison restarts the ledger from the request
    at hand: a different prefix (system prompt or tool schemas), a history
    that no longer holds the last request's positions, a front that moved
    back, or a front that fell inside a block.

    A position is an atom index together with the digest of the message that
    opens that atom ({!Runtime_model_input_tail_window.atom_opening_digest}).
    Each request records the digests of its front and last atoms, and each
    block the digest of its first. The history the next request is composed
    from is asked for both of the last request's positions: when either index
    is gone or opens with another message, the ledger restarts. The atom
    count is not compared. A history can lose an unsaved attempt's atom and
    keep every position, or keep its count while an index now opens with
    another message; only the digests tell the two apart. The atoms between
    the two positions cannot be proved, so no rule keeps part of the blocks
    after a shrink. A front move over measured blocks only subtracts
    them. A front move over a block of unknown size (the cold-start block)
    keeps the measured blocks and leaves the total unknown until the next
    usage; the block appended in that same request can then never be
    measured, and when it is evicted in turn the same happens once more.
    The chain ends at the first eviction whose request appends nothing.
    A front at atom 0 always starts at that unmeasured block, so the move
    that first adds the omission preamble to the request also leaves the
    total unknown, and the next sample counts the preamble with the rest.

    A difference that comes out negative is reported and not written into
    any block. A usage
    reporting zero input tokens is not a measurement; {!usage_of_counts}
    turns it into [None].

    The table is process memory keyed by keeper and runtime. Token counts
    are the provider's, so the same atoms carried on another runtime are a
    separate ledger. The turn driver records responses in this table and
    applies boundary/refusal moves to a candidate-local working value. An
    unaccepted narrower request never replaces the next turn's observation. *)

(** The positions a request carried, named by their opening messages. *)
type carried_ends =
  | No_atom_carried
      (** The request names no position: its history's lookup did not give a
          digest at both [first_atom] and [atom_count - 1]. That is a request
          that carried no atom, [first_atom = atom_count], of an empty history
          or of a non-empty one. The turn driver also records it for a lookup
          that gives only one of the two, which a lookup over the history the
          counts were read from does not. Nothing is checked against it later,
          and it starts no block. *)
  | Carried_atoms of
      { front_digest : string
            (** Opening-message digest of atom [first_atom]. *)
      ; end_digest : string
            (** Opening-message digest of atom [atom_count - 1], the newest
                carried atom. *)
      }

(** What a turn's first request does with the results of the turn that ended
    before it. It decides what the turn builds on. The dispatch says it from
    how it sends the results of ended turns at all, not from what one request
    happened to carry, and it is read only at a request that opens a turn
    ({!opens_turn}). *)
type finished_turn =
  | Carried_whole
      (** As the turn's own requests sent them. The next turn builds on the
          turn's last request. *)
  | Left_as_markers
      (** As markers. The next turn is taken to build on the turn's first
          request, as if all the turn added left with its results. Some of
          it stays: the assistant's text, results under the marker
          threshold, the markers themselves. A turn's growth is measured
          from the first count of the turn before it, so what a turn
          usually leaves behind is inside the growth. The peak is off only
          by how much that changes from one turn to the next: low after a
          turn that leaves more behind than the turns measured before it. *)

(** One request as the projection handed it to the provider. *)
type request =
  { prefix_digest : string
        (** SHA-256 of the system prompt and tool schemas: the fixed prefix F. *)
  ; first_atom : int  (** Index of the oldest carried atom in the durable history. *)
  ; atom_count : int  (** Atoms the durable history held when this request was built. *)
  ; ends : carried_ends
        (** Both carried positions as that request's history opened them. *)
  ; tail_bytes : int
        (** Bytes of the per-request tail (extra system context and other
            pinned messages), measured with the request encoder. *)
  ; turn_context : bool
        (** The request carried the per-turn context message, so its usage
            is not a sample. *)
  ; turn_boundary : int option
        (** The atom the turns that ended stop before, as the dispatch that
            built the request read it from the turn log; [None] when the
            dispatch could not name it. Two requests under the same boundary
            belong to the same turn. *)
  ; finished_turn : finished_turn
        (** What this request did with the turn that ended before it. *)
  ; demote_before : int
        (** Atoms below this index went out with their aged tool results as
            markers; 0 when nothing was demoted. *)
  ; working_state : string option
        (** The Librarian working state the request carried ahead of its
            atoms; [None] when it carried none. *)
  }

type usage =
  { input_tokens : int  (** The provider's inclusive prompt total. *)
  ; cache_read_input_tokens : int
  }

type block =
  { block_first_atom : int
  ; block_end_atom : int  (** Exclusive. *)
  ; block_first_digest : string
        (** Opening-message digest of [block_first_atom], read from the
            history the block was first carried in; an eviction that stops at
            this block moves the front to this position. *)
  ; tokens : int option
        (** Provider-counted tokens of the atoms in this range, including the
            change of the per-request tail between the two requests that
            bracket it. [None] while no usage has bracketed the range. *)
  }

(** How much one turn grew the input while the window stayed. Every count
    is the provider's [input_tokens] for a request, a sample or not: the
    turn's first request carries the turn context and is still the largest
    request of a turn that calls no tool. A request with the turn context
    opens a turn, unless it ran under the turn boundary of the request before
    it ({!opens_turn}). A turn's growth is its largest count less the count it
    builds on, which is what its first request kept of the turn before it
    ({!finished_turn}): that turn's last count when carried whole, its first
    count when left as markers. Measured from the last count either way, a
    turn that follows a large one left as markers would read as shrinking,
    and one that follows a quiet turn as growing by all of its own results.
    A front that moves opens another window: the counts start over with it,
    and the largest growth stays, since how much one turn grows does not
    depend on where the window opens. A window that opens later in a turn
    has no first count for that turn, so the turn after it has nothing to
    build on under {!Left_as_markers}. A restart starts all of it over.
    Only {!observe} changes it and only {!next_turn_peak} reads it. *)
type turn_growth

type t =
  { prefix_digest : string
  ; total_tokens : int option
        (** [input_tokens] of the last sample: the prefix, the omission
            preamble once the front is past atom 0, and the carried atoms.
            [None] after a front move removed atoms whose tokens were unknown,
            until the next sample. *)
  ; measured_end_atom : int option
        (** [atom_count] of the request [total_tokens] describes. *)
  ; measured_demote_before : int option
        (** [demote_before] of the request [total_tokens] describes. *)
  ; blocks : block list  (** Oldest first, contiguous over the carried range. *)
  ; last : request
  ; last_usage : usage option
  ; growth : turn_growth
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
  | History_reset
      (** The history no longer opens the last request's front or newest atom
          with the message that request carried, or has no atom there;
          restarted. *)

type observation =
  { ledger : t
  ; event : event
  ; delta_tokens : int option
        (** [input_tokens] minus the previous measured total, corrected for
            evicted blocks, when both were known. *)
  ; tail_delta_bytes : int  (** Tail bytes of this request minus the previous. *)
  }

val observe
  :  digest_at:(int -> string option)
  -> t option
  -> request
  -> usage option
  -> observation
(** Pure step. [None] starts a ledger from the request. [digest_at] is
    {!Runtime_model_input_tail_window.atom_opening_digest} over the history
    [request] was composed from; the last request's positions are checked
    against it, and a block appended from it is named by it. *)

val usage_of_counts : input_tokens:int -> cache_read_input_tokens:int -> usage option
(** [None] unless [input_tokens] is positive: a zero-filled usage is the
    shape of a response that reported nothing. *)

val holds : digest_at:(int -> string option) -> t -> bool
(** Whether the history [digest_at] reads still opens the last request's
    front and newest atom with the messages that request recorded; [true] for
    a last request that carried no atom. The check [observe] makes, for a
    caller that has to decide before it composes whether the ledger's front
    names an atom of this history (RFC keeper-context-window-in-tokens
    §10.3). *)

val opens_turn : t option -> turn_context:bool -> turn_boundary:int option -> bool
(** Whether a request with [turn_context] under [turn_boundary] opens a turn
    after the ledger's last request. It does when it carries the turn
    context, unless both requests name the same turn boundary: no turn ended
    between them, so a dispatch took up the open turn again and sent the
    context a second time. A boundary either dispatch could not name says
    nothing, and the request opens a turn. With no ledger, the turn context
    alone decides. {!observe} applies the same rule to the request it is
    given. *)

val last_input_tokens : t -> int option
(** Provider-counted [input_tokens] of the last request recorded in this ledger,
    whether or not that request was a sample and whether or not turn growth has
    been measured yet. [None] when the last request went uncounted. *)

val next_turn_peak : finished_turn:finished_turn -> t -> int option
(** The input the next turn is expected to reach while the window stays:
    what its first request keeps of the turn in hand, plus the largest growth
    of a turn that finished since the ledger started, the turn in hand
    included as if it had just finished. [finished_turn] says what that
    first request will do with the turn in hand. [None] while either part is
    unknown. The turn a window opened in builds on no count under that
    window, so it adds no growth. A ledger's first window has none until its
    second turn has opened. *)

val known_tokens : t -> int
(** Sum of the measured blocks' tokens. *)

val unmeasured_atoms : t -> int
(** Carried atoms not covered by a measured block. *)

val event_to_string : event -> string

val to_json : t -> Yojson.Safe.t
(** Counts and totals only. *)

val observation_to_json : observation -> Yojson.Safe.t

val prefix_digest : system_prompt:string -> tools:Agent_core.Tool.t list -> string
(** SHA-256 hex over the system prompt and the tool schemas in declaration
    order, the same JSON the request carries. *)

(** Process-wide table, one ledger per keeper and runtime. *)
module Table : sig
  (** One ledger per (keeper, runtime, session). The session is the history
      the atoms are positions in: a keeper's trace id, or the recovery
      worker's own session, so neither reads the other's front. *)

  val observe
    :  keeper_name:string
    -> runtime_id:string
    -> session_id:string
    -> digest_at:(int -> string option)
    -> request:request
    -> usage:usage option
    -> observation

  val lookup : keeper_name:string -> runtime_id:string -> session_id:string -> t option

  type in_history =
    | Holds of t  (** The pair's ledger, whose positions this history holds. *)
    | Dropped_stale of t
        (** The pair's ledger did not hold ({!holds}) and was removed: its
            front and blocks name atoms of another history, so it neither
            chooses the front nor answers a refusal. The next observed
            request starts a new one. *)
    | Absent

  val lookup_in_history
    :  keeper_name:string
    -> runtime_id:string
    -> session_id:string
    -> digest_at:(int -> string option)
    -> in_history
  (** The pair's ledger as the history a request composes from sees it
      (RFC keeper-context-window-in-tokens §10.3: the positions are checked
      when the request is composed, and a ledger that fails restarts). The
      restart is the removal: a ledger needs a request and its usage to start
      from, and the request being composed has neither yet. *)

  module For_testing : sig
    val reset : unit -> unit
  end
end
