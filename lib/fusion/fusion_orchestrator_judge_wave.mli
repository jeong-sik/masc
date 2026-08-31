(** Judge wave helpers for {!Fusion_orchestrator}. *)

(** One first-pass judge run: its spec, derived identity, result, and elapsed
    seconds since the wave clock started. Timeout classification is not carried
    here — {!Fusion_types.judge_failure_is_timeout} derives it from the typed
    failure wherever it is needed (the sink does exactly that), so a second
    boolean copy would be a duplicate of the same fact. *)
type judge_run =
  Fusion_policy.judge_spec
  * string
  * ( Fusion_types.judge_synthesis * Fusion_types.usage
    , Fusion_types.judge_failure * Fusion_types.usage )
    result
  * float option

type clock

val make_runtime_clock : unit -> clock
(** Build a clock from the current domain-local {!Masc_eio_env}. Missing
    runtime env never blocks execution and produces unavailable elapsed observations. *)

val elapsed_since_t0 : clock -> float option

(** Output-token budget for one first-pass judge: its own [jmax_output_tokens]
    when set, otherwise the preset's [judge_max_output_tokens] (the budget the
    single/refine/meta judges already use). Pure. *)
val first_judge_max_tokens
  :  preset:Fusion_policy.preset
  -> Fusion_policy.judge_spec
  -> int option

(** Whether one first-pass judge gets web tools: the union of the
    request/panel-derived [judge_web_tools] and the judge's own [jweb_tools].
    Pure. *)
val first_judge_web_tools
  :  judge_web_tools:bool
  -> Fusion_policy.judge_spec
  -> bool

(** Response deadline for one first-pass judge: its own [jtimeout_s] when set,
    otherwise the preset's [judge_timeout_s]. Pure. *)
val first_judge_timeout_s
  :  preset:Fusion_policy.preset
  -> Fusion_policy.judge_spec
  -> float option

(** Run every first-pass judge concurrently over the same panel.

    [judge_web_tools] is the request/panel-derived setting
    ({!Fusion_policy.judge_web_tools_of}); each judge's own [jweb_tools] is
    unioned with it, so a request that asks for web tools reaches the first
    judges exactly as it reaches the single and meta judges.

    Output budget per judge is the judge's own [jmax_output_tokens] when set,
    otherwise the preset's [judge_max_output_tokens]. *)
val run_first_judges
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> preset:Fusion_policy.preset
  -> panel:Fusion_types.panel_outcome list
  -> question:string
  -> clock:clock
  -> judge_web_tools:bool
  -> on_tool_trace:(Fusion_types.tool_trace -> unit)
  -> Fusion_policy.judge_spec list
  -> judge_run list

val first_judge_nodes : judge_run list -> Fusion_types.judge_outcome list

val successful_syntheses
  :  judge_run list
  -> (string * Fusion_types.judge_synthesis * Fusion_types.usage) list

val successful_pair_syntheses
  :  (string * (Fusion_types.judge_synthesis * Fusion_types.usage, 'err) result) list
  -> (string * Fusion_types.judge_synthesis * Fusion_types.usage) list

val firsts_usage : judge_run list -> Fusion_types.usage

val all_fail_error_of_runs
  :  fallback:Fusion_types.judge_failure
  -> judge_run list
  -> Fusion_types.judge_failure * Fusion_types.usage
