(** Env_config_exec_timeout — per-caller subprocess execution timeout SSOT (#10426).

    Pattern adopted from {!Env_config_oas_bridge} (#10094).  Replaces
    40+ hardcoded [~timeout_sec:N.N] literals scattered across
    [lib/keeper/*] and [lib/exec/*].  Each caller is named so:

      1. its current literal is preserved as a typed default;
      2. the operator can override any single caller's budget via
         [MASC_EXEC_TIMEOUT_<CALLER>_SEC] without touching others;
      3. unknown callers (typo, future caller without a typed
         default) fall through to [global_default_sec].

    The lookup order is per-caller env > per-caller hardcoded default
    > [MASC_EXEC_TIMEOUT_DEFAULT_SEC] > [global_default_sec]. *)

type caller =
  | Shell                     (** keeper_exec_shell hot-path subprocess (60s) *)
  | Fs                        (** keeper_exec_fs file ops (30s) *)
  | Preflight                 (** keeper_exec_preflight checks (10s) *)
  | Repo_readiness            (** keeper_repo_readiness git status (10s) *)
  | Sandbox                   (** keeper_sandbox_control / keeper_shell_docker probes (2s) *)
  | Pr_review                 (** keeper_tool_pr_review gh CLI reads (15s) *)
  | Pr_review_post            (** keeper_tool_pr_review gh pr review write (30s) *)
  | Dispatch                  (** exec_dispatch routine execution (120s) *)
  | Memory_audit              (** keeper_exec_memory short audits (3s) *)
  | Alerting                  (** keeper_alerting fanout (Slack/webhook POST + gh issue create) (20s) *)
  | Gh_shared                 (** keeper_gh_shared gh CLI quick query (5s) *)
  | Status_detail             (** keeper_status_detail health probes (5/10s) *)
  | Turn_sandbox              (** keeper_turn_sandbox_runtime (2/5s) *)
  | Turn_up                   (** keeper_turn_up_create / _update sandbox (15s) *)
  | Git_meta                  (** local git metadata (rev-parse, remote get-url) (10s) *)
  | Autoresearch_git_meta     (** autoresearch local git metadata reads (10s) *)
  | Autoresearch_git_mutation (** autoresearch local git mutations (30s) *)
  | Shell_probe               (** PATH probes via [command -v <name>] (2s) *)
  | Graphql                   (** Graphql_client.{request,query,mutate} HTTP calls (10s) *)
  | Http                      (** http_post_json_text_with_status probes (15s) *)
  | Startup                   (** server bootstrap docker preflight + room takeover read (30s) *)
  | Auto_responder            (** auto_responder cli spawn with stdin prompt (120s) *)
  | Build_identity            (** build identity git probe (5s) *)
  | Voice                     (** voice bridge local playback subprocess (60s) *)
  | Coord_identity            (** coord tty identity probe (5s) *)
  | Dashboard                 (** dashboard safe_autonomy short heartbeat (3s) *)
  | Http_routes               (** workspace api git command via http (15s) *)
  | Test                      (** test fixtures driving exec runtime (30s) *)
  | Unknown of string

(** Hardcoded default seconds for each known caller.  Preserves
    current literals; operator override via env var supersedes. *)
let global_default_sec = 30.0

let caller_key = function
  | Shell -> "shell"
  | Fs -> "fs"
  | Preflight -> "preflight"
  | Repo_readiness -> "repo_readiness"
  | Sandbox -> "sandbox"
  | Pr_review -> "pr_review"
  | Pr_review_post -> "pr_review_post"
  | Dispatch -> "dispatch"
  | Memory_audit -> "memory_audit"
  | Alerting -> "alerting"
  | Gh_shared -> "gh_shared"
  | Status_detail -> "status_detail"
  | Turn_sandbox -> "turn_sandbox"
  | Turn_up -> "turn_up"
  | Git_meta -> "git_meta"
  | Autoresearch_git_meta -> "autoresearch_git_meta"
  | Autoresearch_git_mutation -> "autoresearch_git_mutation"
  | Shell_probe -> "shell_probe"
  | Graphql -> "graphql"
  | Http -> "http"
  | Startup -> "startup"
  | Auto_responder -> "auto_responder"
  | Build_identity -> "build_identity"
  | Voice -> "voice"
  | Coord_identity -> "coord_identity"
  | Dashboard -> "dashboard"
  | Http_routes -> "http_routes"
  | Test -> "test"
  | Unknown caller -> caller

(** Exported for tests that pin the per-caller default table. *)
let known_callers () =
  [
    Shell;
    Fs;
    Preflight;
    Repo_readiness;
    Sandbox;
    Pr_review;
    Pr_review_post;
    Dispatch;
    Memory_audit;
    Alerting;
    Gh_shared;
    Status_detail;
    Turn_sandbox;
    Turn_up;
    Git_meta;
    Autoresearch_git_meta;
    Autoresearch_git_mutation;
    Shell_probe;
    Graphql;
    Http;
    Startup;
    Auto_responder;
    Build_identity;
    Voice;
    Coord_identity;
    Dashboard;
    Http_routes;
    Test;
  ]

let known_default_sec = function
  | Shell -> Some 60.0
  | Fs -> Some 30.0
  | Preflight | Repo_readiness | Gh_shared -> Some 10.0
  | Status_detail -> Some 5.0
  | Sandbox -> Some 10.0
  | Turn_sandbox | Shell_probe -> Some 2.0
  | Pr_review | Turn_up -> Some 15.0
  (* #10594 site 1: bumped 15.0 → 20.0 because gh issue create + Slack
     POST + webhook fanout share this caller and the gh path can hit
     ~18s under GitHub API load.  Operators can env-override down via
     MASC_EXEC_TIMEOUT_ALERTING_SEC if the wider budget masks a real
     stuck call. *)
  | Alerting -> Some 20.0
  | Pr_review_post -> Some 30.0
  | Dispatch -> Some 120.0
  | Memory_audit -> Some 3.0
  | Git_meta | Autoresearch_git_meta -> Some 10.0
  | Autoresearch_git_mutation -> Some 30.0
  (* Defaults for the new variants below preserve the literals each
     site previously held — see #10426 review (#13081) for the
     site-by-site mapping.  Operators can override via
     MASC_EXEC_TIMEOUT_<CALLER>_SEC without touching the others. *)
  | Graphql -> Some 10.0          (* relation_materializer / dashboard graphql 8-10s *)
  | Http -> Some 15.0             (* tool_local_runtime_verify probe was 15s *)
  | Startup -> Some 30.0          (* server_bootstrap docker preflight 30s *)
  | Auto_responder -> Some 120.0  (* auto_responder cli spawn was 120s — under-budget regression risk *)
  | Build_identity -> Some 5.0    (* git probe was 5s *)
  | Voice -> Some 60.0            (* local playback was 60s — under-budget regression risk *)
  | Coord_identity -> Some 5.0    (* tty probe was 5s *)
  | Dashboard -> Some 3.0         (* short heartbeat was 3s *)
  | Http_routes -> Some 15.0      (* workspace git command via http was 15s *)
  | Test -> Some 30.0             (* test fixtures, slow_command path keeps 30s ceiling *)
  | Unknown _ -> None

let upper_case s =
  s
  |> String.map (fun c ->
       if c >= 'a' && c <= 'z' then
         Char.chr (Char.code c - 32)
       else if c = '-' then '_'
       else c)

let per_caller_env_var ~caller =
  Printf.sprintf "MASC_EXEC_TIMEOUT_%s_SEC" (upper_case (caller_key caller))

let global_env_var = "MASC_EXEC_TIMEOUT_DEFAULT_SEC"

(** Empty-string env vars (the [Unix.putenv NAME ""] pattern used
    by tests to clear an override) must NOT be treated as "set".
    [Sys.getenv_opt] returns [Some ""] in that case. *)
let trimmed_value_opt name =
  match Env_config_core.raw_value_opt name with
  | Some v ->
    let t = String.trim v in
    if t = "" then None else Some t
  | None -> None

(** [timeout_sec ~caller ()] resolves the subprocess execution timeout
    for [caller].  Lookup order:

      1. Per-caller env [MASC_EXEC_TIMEOUT_<CALLER>_SEC].
      2. Per-caller checked-in default ([known_default_sec]).
      3. Global env [MASC_EXEC_TIMEOUT_DEFAULT_SEC] — only consulted
         for UNKNOWN callers.  Treating it as an override would let
         one slow operation silently shift every caller's budget;
         that is a footgun mirroring the precedent in
         {!Env_config_oas_bridge}.
      4. [global_default_sec] (30s) hardcoded final fallback. *)
let timeout_sec ~caller () =
  let per_caller_env = per_caller_env_var ~caller in
  match trimmed_value_opt per_caller_env with
  | Some v ->
    Safe_ops.float_of_string_with_default
      ~default:global_default_sec v
  | None ->
    match known_default_sec caller with
    | Some d -> d
    | None ->
      match trimmed_value_opt global_env_var with
      | Some v ->
        Safe_ops.float_of_string_with_default
          ~default:global_default_sec v
      | None -> global_default_sec

(** [timeout_sec_int ~caller ()] resolves the same value as
    [timeout_sec] but rounded UP to the nearest second.  Use this at
    call sites whose downstream helper signs [~timeout_sec:int] (e.g.
    {!Tool_local_runtime_http.http_post_json_text_with_status},
    {!Worker_runtime_docker.run_process_with_timeout}).  Rounding up
    rather than truncating preserves the operator's intended budget
    when the env var is fractional. *)
let timeout_sec_int ~caller () =
  let f = timeout_sec ~caller () in
  if Float.is_nan f || f <= 0.0 then 1
  else int_of_float (Float.ceil f)
