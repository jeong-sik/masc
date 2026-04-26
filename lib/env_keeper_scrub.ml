(* Exact keys copied from claude-code's GHA_SUBPROCESS_SCRUB list at
   src/utils/subprocessEnv.ts:15-53.

   Each group is documented in the reference. Rationale preserved so a
   future reader can justify additions or removals. *)

let scrub : string list =
  [ (* Anthropic auth — MASC re-reads these per-request, subprocesses don't
       need them and leaking them into a sandboxed container creates an
       escape surface. *)
    "ANTHROPIC_API_KEY"
  ; "CLAUDE_CODE_OAUTH_TOKEN"
  ; "ANTHROPIC_AUTH_TOKEN"
  ; "ANTHROPIC_FOUNDRY_API_KEY"
  ; "ANTHROPIC_CUSTOM_HEADERS"
  ; (* OTLP exporter headers — documented to carry Authorization: Bearer
       tokens for monitoring backends; read in-process by the OTEL SDK. *)
    "OTEL_EXPORTER_OTLP_HEADERS"
  ; "OTEL_EXPORTER_OTLP_LOGS_HEADERS"
  ; "OTEL_EXPORTER_OTLP_METRICS_HEADERS"
  ; "OTEL_EXPORTER_OTLP_TRACES_HEADERS"
  ; (* Cloud provider creds — same pattern (lazy SDK reads). *)
    "AWS_SECRET_ACCESS_KEY"
  ; "AWS_SESSION_TOKEN"
  ; "AWS_BEARER_TOKEN_BEDROCK"
  ; "GOOGLE_APPLICATION_CREDENTIALS"
  ; "AZURE_CLIENT_SECRET"
  ; "AZURE_CLIENT_CERTIFICATE_PATH"
  ; (* GitHub Actions OIDC — consumed by the action's JS before the keeper
       spawns; leaking these allows minting an App installation token. *)
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
  ; "ACTIONS_ID_TOKEN_REQUEST_URL"
  ; (* GitHub Actions artifact/cache API — cache poisoning pivot. *)
    "ACTIONS_RUNTIME_TOKEN"
  ; "ACTIONS_RUNTIME_URL"
  ; (* Workflow-level duplicates — ALL_INPUTS contains api keys as JSON. *)
    "ALL_INPUTS"
  ; "OVERRIDE_GITHUB_TOKEN"
  ; "DEFAULT_WORKFLOW_TOKEN"
  ; "SSH_SIGNING_KEY"
  ]
;;

let pass : string list =
  [ (* Job-scoped GitHub tokens — documented consumer is gh/git. *)
    "GH_TOKEN"
  ; "GITHUB_TOKEN"
  ; (* SSH agent forwarding socket — short-lived, per-session. *)
    "SSH_AUTH_SOCK"
  ; (* Git user identity + config wiring; SSOT'd elsewhere but allowed to
       pass when set by host. *)
    "GIT_AUTHOR_NAME"
  ; "GIT_AUTHOR_EMAIL"
  ; "GIT_COMMITTER_NAME"
  ; "GIT_COMMITTER_EMAIL"
  ; "GIT_CONFIG_GLOBAL"
  ; "GIT_CONFIG_COUNT"
  ]
;;

let scrub_table =
  let t = Hashtbl.create (List.length scrub) in
  List.iter (fun k -> Hashtbl.replace t k ()) scrub;
  t
;;

let is_scrubbed key = Hashtbl.mem scrub_table key

let key_of_entry entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some i -> String.sub entry 0 i
;;

let filter_environment existing =
  Array.to_list existing
  |> List.filter (fun e -> not (is_scrubbed (key_of_entry e)))
  |> Array.of_list
;;
