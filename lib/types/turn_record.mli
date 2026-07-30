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

type input_component_id =
  | Prompt_block of Prompt_block_id.t
  | Tool_schemas
  | Message_user
  | Message_system
  | Message_assistant_text
  | Message_thinking
  | Message_redacted_thinking
  | Message_tool_use
  | Message_tool_result
  | Message_image
  | Message_document
  | Message_audio

type input_component =
  { component : input_component_id
  ; bytes : int
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
  ; cache_creation_input_tokens : int option
  ; cache_read_input_tokens : int option
    (* The provider reports these alongside [input_tokens]
       (Agent_sdk.Types.api_usage) and this record used to drop them, so a reader
       could not tell whether a large [input_tokens] was mostly cache reads. That
       matters against [context_window] below: the fill percentage it denominates is
       read as pressure on the compaction ceiling, and cache-heavy turns and
       genuinely large prompts are different situations with the same numerator.
       [None] when the provider reported no usage. *)
  }

type request_wire_observation =
  { runtime_profile : string
  ; body_bytes : int
  }

type t =
  { execution_ids : Ids.Execution_id.t list (* tool calls in this turn *)
  ; keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
    (* RFC-0233 §7 — "<trace_id>#<absolute_turn>" join key for chat/board.
       The decoder requires it to match [trace_id] and [absolute_turn]. *)
  ; blocks : prompt_block list (* assembly order *)
  ; input_components : input_component list
    (* Exact UTF-8/JSON payload bytes attributed to the concrete prompt blocks,
       tool schemas, and content blocks that formed the dispatched input.
       This excludes provider envelope metadata and is therefore shown beside,
       never substituted for, [request_wire_observation]. *)
  ; runtime_profile : string
  ; model : string option
    (* RFC-0233 §2.2/§2.3 — boundary-redacted runtime model label, the
       same value the execution receipt surfaces (RFC-0132 redaction
       SSOT). [None] on error turns before runtime grounding; the inspector
       renders absence rather than a fabricated name. *)
  ; finish_reason : string option
    (* RFC-0233 §2.3 — keeper turn stop reason, serialized via the
       receipt SSOT [Keeper_execution_receipt.stop_reason_to_string].
       [None] when the turn errored before a stop reason was recorded;
       an unknown reason is never collapsed to a fake "stop". *)
  ; context_window : int option
    (* RFC-0233 §8 — keeper-resolved effective context budget (tokens) for
       this turn, the denominator the dashboard ctx-fill% uses. [None] on
       the error path; the inspector renders absence rather than the
       fabricated 200K. This is the keeper compaction ceiling
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
  ; request_latency_ms : int option
    (* RFC-0233 §9 — wall-clock duration of the provider call in
       milliseconds, sourced from OAS
       [inference_telemetry.request_latency_ms] (the OAS transport layer
       synthesizes it for every provider — [complete_common.patch_telemetry]
       non-streaming, [complete_stream] streaming — so it is populated
       whenever a response is produced). [None] on the error path; the
       inspector renders absence rather than a fabricated duration
       for the response-generation phase. Phase-level splits
       (prefill/decode) are deliberately deferred: only the provider's
       native timing objects carry prefill/predicted durations and most
       keepers' runtimes do not report them, so emitting them would show
       mostly-empty columns rather than measured signal. [ttfrc_ms] is the
       one phase-level signal every streaming provider reports, so it is
       lifted to its own §10 field below. *)
  ; ttfrc_ms : float option
    (* RFC-0233 §10 — time-to-first-response-chunk in milliseconds
       (wall-clock), sourced from OAS [inference_telemetry.ttfrc_ms]. Unlike
       [request_latency_ms] (end-to-end), this measures only the wait for
       the first response chunk, isolating time-to-first-token on the
       streaming path. The OAS streaming transport ([complete_stream]) fills
       it for every provider as soon as the first SSE chunk arrives, so it
       is populated across the (streaming) keeper fleet; non-streaming turns
       and the error path leave it [None]. The decode (post-first-chunk)
       duration is intentionally NOT derived as
       request_latency_ms - ttfrc_ms: that would fabricate a number
       indistinguishable from a measurement (§9.6), so decode stays
       not_recorded until a provider reports it natively. *)
  ; request_wire_observation : request_wire_observation option
    (* Runtime id and exact serialized body size for the latest request OAS
       serialized. Admitted requests arrive through OAS's pre-dispatch
       observer; a locally rejected [Request_body_too_large] arrives through
       that typed error's measured [actual_bytes]. This is not derived from
       prompt blocks or provider token usage. [None] means this turn ended
       before OAS exposed either exact measurement; both JSON fields are then
       required explicit nulls. *)
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

val prompt_block_to_json : prompt_block -> Yojson.Safe.t
val input_component_id_to_string : input_component_id -> string
val input_component_to_json : input_component -> Yojson.Safe.t

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Fails loudly on malformed rows (missing fields, unparseable
    execution ids, unknown block names, or mismatched turn refs) instead
    of repairing them — RFC-0233 §4. *)

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
