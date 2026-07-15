(** Judge wave helpers for {!Fusion_orchestrator}. *)

type judge_run =
  Fusion_policy.judge_spec
  * string
  * ( Fusion_types.judge_synthesis * Fusion_types.usage
    , Fusion_types.judge_failure * Fusion_types.usage )
    result
  * float
  * bool

type clock

val make_clock
  :  now_opt:(unit -> float option)
  -> clock

val make_runtime_clock : unit -> clock
(** Build a clock from the current domain-local {!Masc_eio_env}. Missing
    runtime env is represented as [None]; execution never depends on this
    observation clock. *)

val elapsed_since_t0 : clock -> float

val run_first_judges
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> preset:Fusion_policy.preset
  -> panel:Fusion_types.panel_outcome list
  -> question:string
  -> clock:clock
  -> judge_web_tools:bool
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

val with_timeout_fallback
  :  run_fallback_judge:(unit -> judge_run option)
  -> judge_run list
  -> judge_run list
(** Append the configured fallback judge when the complete first-judge list
    failed only with timeouts. *)

val run_fallback_judge
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> preset:Fusion_policy.preset
  -> panel:Fusion_types.panel_outcome list
  -> question:string
  -> clock:clock
  -> judge_web_tools:bool
  -> unit
  -> judge_run option
