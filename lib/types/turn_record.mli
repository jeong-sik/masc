(** RFC-0233 §2.2 — one record per keeper turn, written at the same
    point that writes the execution receipt.

    Block *text* is never duplicated into the record; [digest] (sha256
    of the raw block text) joins against the existing prompt/receipt
    stores. Diffing two consecutive records by [(block, digest)] answers
    "which instruction blocks entered, left, or changed between turns".

    The assembly chain re-runs once per agent-core turn inside one keeper turn.
    When a request reached the wire boundary, [blocks] and
    [input_components] describe that same latest serialized request. If no
    request reached the boundary, [blocks] records the last assembly and
    [input_components] is [None]. *)

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
       (Agent_core.Types.api_usage) and this record used to drop them, so a reader
       could not tell whether a large [input_tokens] was mostly cache reads. That
       matters against [context_window] below: the fill percentage it denominates is
       read as request-window pressure, and cache-heavy turns and
       genuinely large prompts are different situations with the same numerator.
       [None] when the provider reported no cache usage. *)
  ; scope : Runtime_usage_scope.t
  }

type request_wire_observation =
  { runtime_profile : string
  ; body_bytes : int
  }

type model_input_measurement =
  | Wire_shape
      (** Blocks the target's dialect will not replay were removed before the
          history was sized, so the budget counted what the request carries. *)
  | Durable_shape
      (** The projection declined and the budget counted the checkpoint's
          shape instead, which includes reasoning the wire deletes. The turn
          is correct and its window is narrower than it needs to be — a
          keeper can sit here indefinitely, because nothing about the decline
          ages out, so this is recorded rather than only logged. *)

type model_input_window =
  { transmitted_atoms : int
  ; total_atoms : int
  ; measurement : model_input_measurement
  }
(** How much of the keeper's own history the dispatched request carried, in
    atoms — one organic user message, or one assistant message together with
    the tool messages answering it.

    Reported beside {!request_wire_observation}, never in place of it: that one
    counts the bytes the provider admitted, this one counts how much
    conversation the turn reached back over. The two do not decompose into each
    other — the admitted bytes also carry pinned context, the synthetic
    preamble, and anything the per-turn assembler appends after the window
    stage has run, none of which these atoms cover.
    [input_components] answers a third question: which block kinds the bytes
    went to.

    Both counts are recorded because a share cannot be recovered from the
    transmitted messages alone: dropped atoms leave no trace, so a reader given
    only the request cannot distinguish a keeper that sent all of a short
    history from one that sent the tail of a long one. Pinned messages are not
    atoms and appear in neither count. *)

type turn_kind =
  | Autonomous
  | Direct

type raw_trace_run_ref =
  { worker_run_id : string
  ; path : string
  ; start_seq : int
  ; end_seq : int
  ; agent_name : string
    (* AGENT_CORE runtime identity for the dispatched run. This is intentionally a
       different namespace from [t.agent_name], which is the Keeper identity;
       the autonomous-turn reader validates it against the selected raw rows. *)
  ; session_id : string
    (* Matches [t.trace_id] and the selected raw rows. *)
  }

type t =
  { execution_ids : Ids.Execution_id.t list (* tool calls in this turn *)
  ; keeper : string
  ; agent_name : string
  ; turn_kind : turn_kind
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
    (* RFC-0233 §7 — required "<trace_id>#<absolute_turn>" join key for
       chat/board. The decoder rejects a key that does not exactly match the
       row's [trace_id] and [absolute_turn]. *)
  ; blocks : prompt_block list (* assembly order *)
  ; input_components : input_component list option
    (* Exact UTF-8/JSON payload bytes attributed to the concrete prompt blocks,
       tool schemas, and content blocks that formed the dispatched input.
       This excludes provider envelope metadata and is therefore shown beside,
       never substituted for, [request_wire_observation]. [None] means exact
       attribution was unavailable; an observed empty input is [Some []]. *)
  ; runtime_profile : string
  ; selected_model : string option
    (* RFC-0233 §2.2/§2.3 — exact model selected by the successful runtime
       attempt, sourced from that attempt's [Runtime_observation]. This is
       durable operator evidence, not an aggregate telemetry label. [None]
       when the turn completed without selected-model evidence; the inspector
       renders absence rather than a fabricated name. *)
  ; finish_reason : string option
    (* RFC-0233 §2.3 — keeper turn stop reason, serialized via the
       receipt SSOT [Keeper_execution_receipt.stop_reason_to_string].
       [None] when the turn errored before a stop reason was recorded;
       an unknown reason is never collapsed to a fake "stop". *)
  ; tool_surface_ref : string option
    (* The tool surface this turn sent, as the canonical Tool_output marker
       for its content-addressed blob. [input_components] answers how many
       bytes the schemas cost; this answers which tools they were, which the
       byte total alone can never recover.

       A marker rather than the list itself: the surface is nearly the same
       from turn to turn -- 9,181 requests carried 69 distinct surfaces over
       one measured day -- so inlining it would grow a 1,640-byte record by
       2,925 bytes to repeat what the blob already holds once. The blob store
       already sees this reference: turn-records sit under the [keepers] root
       the maintenance scan walks, and the scan recognises a canonical marker
       wherever it appears.

       [None] when the turn recorded no surface. *)
  ; context_window : int option
    (* RFC-0233 §8 — keeper-resolved effective context budget (tokens) for
       this turn, the denominator the dashboard ctx-fill% uses. [None] on
       the error path; the inspector renders absence rather
       than the fabricated 200K. This is the keeper conversation ceiling
       ([max_context]), not the provider's per-request num-ctx cap (an
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
       milliseconds, sourced from AGENT_CORE
       [inference_telemetry.request_latency_ms] (the AGENT_CORE transport layer
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
       (wall-clock), sourced from AGENT_CORE [inference_telemetry.ttfrc_ms]. Unlike
       [request_latency_ms] (end-to-end), this measures only the wait for
       the first response chunk, isolating time-to-first-token on the
       streaming path. The AGENT_CORE streaming transport ([complete_stream]) fills
       it for every provider as soon as the first SSE chunk arrives, so it
       is populated across the (streaming) keeper fleet; non-streaming turns
       and the error path leave it [None]. The decode (post-first-chunk)
       duration is intentionally NOT derived as
       request_latency_ms - ttfrc_ms: that would fabricate a number
       indistinguishable from a measurement (§9.6), so decode stays
       not_recorded until a provider reports it natively. *)
  ; request_wire_observation : request_wire_observation option
  ; model_input_window : model_input_window option
    (* [None] is an explicit observation that no model-input projection ran for
       this turn — a runtime that assembles its own input, or a turn that ended
       before any cut was selected. It is not a zero-length history. *)
  ; raw_trace_run_ref : raw_trace_run_ref option
    (* Exact AGENT_CORE run selected by this turn's completed provider dispatch.
       [None] is an explicit observation that the raw-trace sink degraded or
       the turn ended before a run reference existed. *)
    (* Runtime id and exact serialized body size for the latest request AGENT_CORE
       serialized. Admitted requests arrive through AGENT_CORE's pre-dispatch
       observer; a locally rejected [Request_body_too_large] arrives through
       that typed error's measured [actual_bytes]. This is not derived from
       prompt blocks or provider token usage. [None] means this turn ended
       before AGENT_CORE exposed either exact measurement; both JSON fields are then
       required explicit nulls. *)
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

type tool_surface_entry =
  { name : string
  ; schema_bytes : int
  }
(** One tool as it went out on a request. [schema_bytes] is that schema
    serialized alone, so entries do not sum to the request's Tool_schemas
    byte count — the wire form carries array framing the parts do not. *)

val tool_surface_to_json : tool_surface_entry list -> Yojson.Safe.t
(** The exact payload the blob behind {!t.tool_surface_ref} holds.

    Declared here, beside the field that points at it, because the writer
    (the keeper turn) and the reader (the context inspector) sit in different
    binaries and would otherwise each spell this shape by hand. Two hand-built
    spellings of one payload is how a reader starts reporting an empty surface
    for a request that carried 147 tools. *)

val tool_surface_of_json :
  Yojson.Safe.t -> (tool_surface_entry list, string) result
(** Inverse of {!tool_surface_to_json}. One malformed entry fails the whole
    listing: dropping it would understate the surface that was actually sent,
    which is the single number the listing exists to report. *)

val prompt_block_to_json : prompt_block -> Yojson.Safe.t
val input_component_id_to_string : input_component_id -> string
val turn_kind_to_string : turn_kind -> string
val raw_trace_run_ref_to_json : raw_trace_run_ref -> Yojson.Safe.t

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Fails loudly on malformed rows instead of repairing them — RFC-0233 §4.
    [turn_ref] and provider-input observation fields are required. Unknown or
    duplicate fields, prompt blocks, or input-component ids, negative byte
    counts, partial request-runtime/request-bytes pairs, and a [turn_ref]
    inconsistent with the row identity are rejected. *)

(** Result of diffing two consecutive records by [(block, digest)]. *)
type block_diff =
  { added : prompt_block list (* in [next] only *)
  ; removed : prompt_block list (* in [prev] only *)
  ; changed : (prompt_block * prompt_block) list (* (prev, next), digest differs *)
  }

val diff_blocks : prev:t -> next:t -> block_diff
(** Blocks are keyed by [block] id. Current rows have unique ids;
    malformed duplicates are rejected by [of_json]. *)

val entries_with_diffs : t list -> (t * block_diff option) list
(** Pair each record (oldest-first) with its diff against the previous
    record of the same trace; [None] at trace boundaries, where the
    whole assembly legitimately changes and a diff would be noise. *)
