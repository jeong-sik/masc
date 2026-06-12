(** RFC-0233 §2.2 — one record per keeper turn, written at the same
    point that writes the execution receipt.

    Block *text* is never duplicated into the record; [digest] (sha256
    of the raw block text) joins against the existing prompt/receipt
    stores. Diffing two consecutive records by [(block, digest)] answers
    "which instruction blocks entered, left, or changed between turns".

    The assembly chain re-runs once per SDK turn inside one keeper turn;
    [blocks] records the LAST SDK turn's assembly, matching the
    last-write-wins semantics of the turn context the receipt already
    uses. *)

type prompt_block =
  { block : Prompt_block_id.t
  ; bytes : int
  ; digest : string (* sha256 hex of the raw block text *)
  }

type sampling =
  { temperature : float option
  ; thinking_budget : int option
  ; enable_thinking : bool option
  }

type usage =
  { input_tokens : int option
  ; output_tokens : int option
  }

type t =
  { execution_ids : Ids.Execution_id.t list (* tool calls in this turn *)
  ; keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; blocks : prompt_block list (* assembly order *)
  ; runtime_profile : string
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Fails loudly on malformed rows (missing fields, unparseable
    execution ids) instead of repairing them — RFC-0233 §4. Unknown
    block names decode as [Prompt_block_id.Other] (that field alone is
    forward-open by design). *)

(** Result of diffing two consecutive records by [(block, digest)]. *)
type block_diff =
  { added : prompt_block list (* in [next] only *)
  ; removed : prompt_block list (* in [prev] only *)
  ; changed : (prompt_block * prompt_block) list (* (prev, next), digest differs *)
  }

val diff_blocks : prev:t -> next:t -> block_diff
(** Blocks are keyed by [block] id; assembly produces at most one block
    per id, so first occurrence wins if a malformed row repeats one. *)
