(** Succession_oas — Adapter bridging MASC succession DNA to OAS Checkpoint.t.

    Converts between MASC's [succession_dna] (generation handoff payload) and
    OAS [Checkpoint.t] (versioned state snapshot). This enables DNA extraction
    and hydration to use OAS's serialization format instead of MASC's custom
    JSON, providing version tracking and cross-agent portability.

    This module is independent of [context_compact_oas] (Phase 1) and
    [oas_checkpoint_bridge] (basic state persistence). It specifically handles
    the succession/handoff pathway.

    Design: MASC-specific fields (goal, progress_summary, pending_actions,
    key_decisions, warnings, generation, trace_id, metrics) are stored in the
    checkpoint's [Context.t] under the [Custom "masc_dna"] scope. This keeps
    the OAS checkpoint schema stable while carrying all succession metadata.

    @since Phase 2 — OAS Checkpoint adapter for succession *)

open Printf

(* ================================================================ *)
(* Feature Flag                                                      *)
(* ================================================================ *)

let use_oas_checkpoint =
  try Sys.getenv "MASC_USE_OAS_CHECKPOINT" = "true"
  with Not_found -> false

(* ================================================================ *)
(* DNA Scope — Custom scope for succession metadata in Context.t     *)
(* ================================================================ *)

(** All DNA metadata lives under [Custom "masc_dna"] scope to avoid
    collisions with other context data. *)
let dna_scope = Agent_sdk.Context.Custom "masc_dna"

(* ================================================================ *)
(* DNA -> OAS Checkpoint                                             *)
(* ================================================================ *)

(** Store a string list as a JSON array in context. *)
let set_str_list ctx key (lst : string list) =
  Agent_sdk.Context.set_scoped ctx dna_scope key
    (`List (List.map (fun s -> `String s) lst))

(** Store succession metrics in context as a JSON object. *)
let set_metrics ctx (m : Succession.succession_metrics) =
  Agent_sdk.Context.set_scoped ctx dna_scope "metrics"
    (`Assoc [
      ("total_turns", `Int m.total_turns);
      ("total_tokens_used", `Int m.total_tokens_used);
      ("total_cost_usd", `Float m.total_cost_usd);
      ("tasks_completed", `Int m.tasks_completed);
      ("errors_encountered", `Int m.errors_encountered);
      ("elapsed_seconds", `Float m.elapsed_seconds);
    ])

(** Convert a MASC [succession_dna] into an OAS [Checkpoint.t].

    The DNA's compressed_context messages are stored in the checkpoint's
    message list (converted via [Llm_client.to_oas_message]). All other
    DNA fields are stored in the checkpoint's context under the
    [Custom "masc_dna"] scope.

    @param dna The succession DNA payload from [Succession.extract_dna].
    @param working_ctx The current working context (for messages and system prompt).
    @return An OAS Checkpoint.t carrying the full DNA payload. *)
let checkpoint_of_dna
    ~(dna : Succession.succession_dna)
    ~(working_ctx : Context_manager.working_context)
  : Agent_sdk.Checkpoint.t =
  let oas_ctx = Agent_sdk.Context.copy working_ctx.oas_context in
  (* Store DNA metadata in the custom masc_dna scope *)
  Agent_sdk.Context.set_scoped oas_ctx dna_scope
    "generation" (`Int dna.generation);
  Agent_sdk.Context.set_scoped oas_ctx dna_scope
    "trace_id" (`String dna.trace_id);
  Agent_sdk.Context.set_scoped oas_ctx dna_scope
    "goal" (`String dna.goal);
  Agent_sdk.Context.set_scoped oas_ctx dna_scope
    "progress_summary" (`String dna.progress_summary);
  Agent_sdk.Context.set_scoped oas_ctx dna_scope
    "compressed_context" (`String dna.compressed_context);
  set_str_list oas_ctx "pending_actions" dna.pending_actions;
  set_str_list oas_ctx "key_decisions" dna.key_decisions;
  set_str_list oas_ctx "memory_refs" dna.memory_refs;
  set_str_list oas_ctx "warnings" dna.warnings;
  set_metrics oas_ctx dna.metrics;
  let messages = List.filter_map Llm_client.to_oas_message working_ctx.messages in
  {
    Agent_sdk.Checkpoint.version = 3;
    session_id = sprintf "succession-%s-gen%d" dna.trace_id dna.generation;
    agent_name = "perpetual-successor";
    model = Agent_sdk.Types.Custom "masc-perpetual";
    system_prompt = Some working_ctx.system_prompt;
    messages;
    usage = {
      Agent_sdk.Types.total_input_tokens = dna.metrics.total_tokens_used;
      total_output_tokens = 0;
      total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0;
      api_calls = dna.metrics.total_turns;
      estimated_cost_usd = dna.metrics.total_cost_usd;
    };
    turn_count = dna.metrics.total_turns;
    created_at = Time_compat.now ();
    tools = [];
    tool_choice = None;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format_json = false;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = Some working_ctx.max_tokens;
    max_total_tokens = None;
    disable_parallel_tool_use = false;
    context = oas_ctx;
    mcp_sessions = [];
  }

(* ================================================================ *)
(* OAS Checkpoint -> DNA                                             *)
(* ================================================================ *)

(** Read a string list from context. Returns empty list if missing. *)
let get_str_list ctx key : string list =
  match Agent_sdk.Context.get_scoped ctx dna_scope key with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

(** Read succession metrics from context. Returns empty metrics if missing. *)
let get_metrics ctx : Succession.succession_metrics =
  match Agent_sdk.Context.get_scoped ctx dna_scope "metrics" with
  | Some (`Assoc _ as json) ->
    (try
      let open Yojson.Safe.Util in
      {
        Succession.total_turns = json |> member "total_turns" |> to_int;
        total_tokens_used = json |> member "total_tokens_used" |> to_int;
        total_cost_usd = json |> member "total_cost_usd" |> to_number;
        tasks_completed = json |> member "tasks_completed" |> to_int;
        errors_encountered = json |> member "errors_encountered" |> to_int;
        elapsed_seconds = json |> member "elapsed_seconds" |> to_number;
      }
    with _ -> Succession.empty_metrics)
  | _ -> Succession.empty_metrics

(** Read a scoped string, returning a default if missing. *)
let get_str ctx key ~default =
  match Agent_sdk.Context.get_scoped ctx dna_scope key with
  | Some (`String s) -> s
  | _ -> default

(** Read a scoped int, returning a default if missing. *)
let get_int ctx key ~default =
  match Agent_sdk.Context.get_scoped ctx dna_scope key with
  | Some (`Int n) -> n
  | _ -> default

(** Extract a MASC [succession_dna] from an OAS [Checkpoint.t].

    Reads DNA metadata from the checkpoint's context (Custom "masc_dna" scope)
    and reconstructs the succession DNA record.

    @param ckpt An OAS Checkpoint.t previously created by [checkpoint_of_dna].
    @return A succession_dna record, or Error if critical fields are missing. *)
let dna_of_checkpoint (ckpt : Agent_sdk.Checkpoint.t)
  : (Succession.succession_dna, string) result =
  let ctx = ckpt.context in
  let generation = get_int ctx "generation" ~default:(-1) in
  let trace_id = get_str ctx "trace_id" ~default:"" in
  if generation < 0 || trace_id = "" then
    Error "Checkpoint missing masc_dna scope metadata (generation or trace_id)"
  else
    Ok {
      Succession.generation;
      trace_id;
      goal = get_str ctx "goal" ~default:"";
      progress_summary = get_str ctx "progress_summary" ~default:"";
      compressed_context = get_str ctx "compressed_context" ~default:"";
      pending_actions = get_str_list ctx "pending_actions";
      key_decisions = get_str_list ctx "key_decisions";
      memory_refs = get_str_list ctx "memory_refs";
      warnings = get_str_list ctx "warnings";
      metrics = get_metrics ctx;
    }

(* ================================================================ *)
(* Checkpoint-based DNA extraction wrapper                           *)
(* ================================================================ *)

(** Extract DNA via OAS Checkpoint serialization format.

    Wraps [Succession.extract_dna] and converts the result to an OAS
    [Checkpoint.t]. The caller can then use [Checkpoint.to_string] for
    persistence instead of [Succession.dna_to_json].

    When [MASC_USE_OAS_CHECKPOINT] is not set, falls back to returning
    the checkpoint alongside the original DNA for comparison.

    @return [(dna, checkpoint)] — the original DNA and its OAS checkpoint form. *)
let extract_dna_via_checkpoint
    ~(working_ctx : Context_manager.working_context)
    ~(session_ctx : Context_manager.session_context)
    ~goal ~generation ~trace_id ~metrics
  : Succession.succession_dna * Agent_sdk.Checkpoint.t =
  let dna = Succession.extract_dna
    ~working_ctx ~session_ctx
    ~goal ~generation ~trace_id ~metrics in
  let ckpt = checkpoint_of_dna ~dna ~working_ctx in
  (dna, ckpt)

(* ================================================================ *)
(* Checkpoint-based hydration                                        *)
(* ================================================================ *)

(** Restore a [working_context] from an OAS Checkpoint carrying DNA.

    Extracts the DNA from the checkpoint, then delegates to
    [Succession.hydrate] for the actual context reconstruction
    (cross-model normalization, system prompt building, etc.).

    @param ckpt An OAS Checkpoint.t created by [checkpoint_of_dna].
    @param spec The successor model specification.
    @return Ok working_context, or Error if checkpoint lacks DNA metadata. *)
let hydrate_from_checkpoint
    (ckpt : Agent_sdk.Checkpoint.t)
    (spec : Succession.successor_spec)
  : (Context_manager.working_context, string) result =
  match dna_of_checkpoint ckpt with
  | Error e -> Error e
  | Ok dna -> Ok (Succession.hydrate dna spec)
