(* Keeper_turn_liveness — phase-buffer cascade liveness decisions and turn
   livelock configuration.

   Provider-specific knowledge lives in [Cascade_capacity_probe]; this
   module routes probeable URLs through that registry without naming
   any single provider.

   Extracted from keeper_unified_turn.ml (L328-499) during the god-file split. *)

open Keeper_types

type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of
      { effective_cascade : string
      ; fallback_cascade : string
      ; probeable_base_urls : string list
      }

let decide_local_only_liveness
      ?resolve_runtime_url
      ~(base_cascade : string)
      ~(effective_cascade : string)
      (labels : string list)
  : local_only_liveness_decision
  =
  let resolve_runtime_url =
    match resolve_runtime_url with
    | Some resolve_runtime_url -> resolve_runtime_url
    | None -> Cascade_runtime_candidate.runtime_url_of_label
  in
  let normalized_base = Keeper_cascade_profile.normalize_declared_name base_cascade in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  if
    (not (String.equal normalized_effective Keeper_config.local_only_cascade_name))
    || String.equal normalized_base Keeper_config.local_only_cascade_name
  then Keep_effective_cascade normalized_effective
  else (
    let probeable_urls =
      labels
      |> List.filter_map resolve_runtime_url
      |> List.filter (fun url -> Cascade_capacity_probe.can_probe ~url)
      |> dedupe_keep_order
    in
    match probeable_urls with
    | [] -> Keep_effective_cascade normalized_effective
    | probeable_base_urls ->
      Probe_local_only_urls
        { effective_cascade = normalized_effective
        ; fallback_cascade = normalized_base
        ; probeable_base_urls
        })
;;

let fail_open_local_only_when_unavailable
      ?resolve_runtime_url
      ?probe_base_url
      ~(base_cascade : string)
      ~(effective_cascade : string)
      (labels : string list)
  : string
  =
  match
    decide_local_only_liveness ?resolve_runtime_url ~base_cascade ~effective_cascade labels
  with
  | Keep_effective_cascade cascade -> cascade
  | Probe_local_only_urls { effective_cascade; fallback_cascade; probeable_base_urls } ->
    let probe_base_url =
      match probe_base_url with
      | Some probe -> Some probe
      | None ->
        (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
         | Some sw, Some net ->
           Some
             (fun base_url ->
               Option.is_some (Cascade_capacity_probe.probe ~sw ~net ~url:base_url ()))
         | _ -> None)
    in
    (match probe_base_url with
     | None -> effective_cascade
     | Some probe ->
       if List.exists probe probeable_base_urls
       then effective_cascade
       else fallback_cascade)
;;

(** PR-B: saturation pre-skip support (provider-agnostic).

    When every label in the resolved cascade points at the same
    [base_url] AND a registered [Cascade_capacity_probe] recognises
    that URL, we can pre-check the probe cache before paying an
    [Agent.run] dispatch.  If the probe reports
    [process_available <= 0] the request would queue on a busy slot
    and very likely blow the keeper turn budget, causing a cascading
    FAILED cycle.  Skipping the turn here keeps the keeper alive
    without burning the budget.

    No provider variant is named — the probe registry is the
    boundary that decides which URLs are probeable.  Adding a new
    local backend (vllm, lmstudio, …) only needs a new probe
    registration. *)

let turn_livelock_max_attempts () =
  Int.max 1 (Env_config_core.get_int ~default:3 "MASC_KEEPER_TURN_LIVELOCK_MAX_ATTEMPTS")
;;

let turn_livelock_stuck_after_sec () =
  Float.max
    1.0
    (Env_config_core.get_float
       ~default:1800.0
       "MASC_KEEPER_TURN_LIVELOCK_STUCK_AFTER_SEC")
;;
