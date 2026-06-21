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
  ; top_p : float option
  ; max_tokens : int option
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
  ; turn_ref : Ids.Turn_ref.t option
    (* RFC-0233 §7 — "<trace_id>#<absolute_turn>" join key for chat/board.
       [option] so pre-§7 rows decode as [None]. *)
  ; blocks : prompt_block list (* assembly order *)
  ; runtime_profile : string
  ; model : string option
    (* RFC-0233 §2.2/§2.3 — boundary-redacted runtime model label, the
       same value the execution receipt surfaces (RFC-0132 redaction
       SSOT). [option] so error turns and pre-grounding rows decode as
       [None]; the inspector renders absence rather than a fabricated
       name. *)
  ; finish_reason : string option
    (* RFC-0233 §2.3 — keeper turn stop reason, serialized via the
       receipt SSOT [Keeper_execution_receipt.stop_reason_to_string].
       [None] when the turn errored before a stop reason was recorded;
       an unknown reason is never collapsed to a fake "stop". *)
  ; context_window : int option
    (* RFC-0233 §8 — keeper-resolved effective context budget (tokens) for
       this turn, the denominator the dashboard ctx-fill% uses. [None] on
       legacy rows or the error path; the inspector renders absence rather
       than the fabricated 200K. This is the keeper compaction ceiling
       ([max_context]), NOT the provider's per-request num-ctx cap (an
       Ollama-only transport detail). *)
  ; price_input_per_million : float option
    (* RFC-0233 §8 — USD per 1M input tokens declared on the runtime
       binding in runtime.toml. [None] when the operator left it unset;
       the inspector renders cost absence rather than a fabricated Claude
       $3/$15 default. *)
  ; price_output_per_million : float option
    (* RFC-0233 §8 — USD per 1M output tokens, same source/absence rule as
       [price_input_per_million]. *)
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

val prompt_block_to_json : prompt_block -> Yojson.Safe.t

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

val entries_with_diffs : t list -> (t * block_diff option) list
(** Pair each record (oldest-first) with its diff against the previous
    record of the same trace; [None] at trace boundaries, where the
    whole assembly legitimately changes and a diff would be noise. *)
