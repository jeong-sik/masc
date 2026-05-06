(* See cascade_attempt_liveness_config.mli for documentation.

   RFC-0022 PR-2/4 §2 — tri-state env flag + per-label budget map. *)

type mode =
  | Off
  | Observe
  | Enforce

let mode_label = function
  | Off -> "off"
  | Observe -> "observe"
  | Enforce -> "enforce"

let env_var_name = "MASC_CASCADE_ATTEMPT_LIVENESS"

let parse_mode raw =
  match String.lowercase_ascii (String.trim raw) with
  | "off" | "0" | "false" | "disabled" -> Off
  | "enforce" | "kill" | "on_kill" -> Enforce
  | "" | "observe" | "default" | "1" | "true" | "shadow" -> Observe
  | _ -> Observe (* unknown values default to Observe — never silently Off *)

(* Cached after first read. Mirrors Keeper_admission_glue.use_new_admission. *)
let mode_cache : mode option ref = ref None

let current_mode () =
  match !mode_cache with
  | Some m -> m
  | None ->
      let m =
        match Sys.getenv_opt env_var_name with
        | None -> Observe
        | Some raw -> parse_mode raw
      in
      mode_cache := Some m;
      m

let reset_cache_for_test () = mode_cache := None

(* Per-label budget catalog — RFC-0022 PR-2 §2.

   Cloud streaming providers (codex_cli, claude_code, gemini_cli) use
   [cloud_fast] as a TTFT-strict budget that matches their typical short
   answer latency. Adaptive-reasoning models (glm-coding which streams
   thinking deltas, kimi-for-coding) get [cloud_thinking].

   Local providers stay on the larger [local_27b] / [local_70b_plus]
   budgets to avoid killing slow local models. *)

let budget_for_label (label : string) : Cascade_attempt_liveness.budget =
  let canon = String.lowercase_ascii (String.trim label) in
  match canon with
  | "codex_cli" | "claude_code" | "claude" | "gemini_cli" | "gemini" ->
      Cascade_attempt_liveness.cloud_fast
  | "glm-coding" | "glm_coding" | "glm" | "kimi_cli" | "kimi-for-coding"
  | "kimi" ->
      Cascade_attempt_liveness.cloud_thinking
  | "ollama_only" | "llama-server" | "llama_server" ->
      Cascade_attempt_liveness.local_27b
  | "local_70b" | "local_70b_plus" | "ollama_70b" ->
      Cascade_attempt_liveness.local_70b_plus
  | _ -> Cascade_attempt_liveness.cloud_fast

(* RFC-0022 §1 — see .mli for contract. *)
let outer_wall_for_attempt
    ~mode ~observer_attached ~per_provider_timeout_s ~provider_label =
  match mode, observer_attached with
  | Enforce, true -> None
  | _, true ->
      let budget_wall =
        (budget_for_label provider_label).Cascade_attempt_liveness.attempt_wall_max
      in
      Option.map
        (fun t -> Float.max t budget_wall)
        per_provider_timeout_s
  | _, false -> per_provider_timeout_s
