(** Tool_schemas_local_runtime — SSOT for local-runtime tool schemas. *)

open Masc_domain

type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

let operation_id = Local_runtime_tool_policy.operation_id

(* Who the tool is for. Both operations stay registered in the catalog. The
   completion-backed contract check and native Ollama probe are explicit Admin
   operations; the metadata-only
   dashboard runtime probe has its own [CanReadState] route authority and does
   not reuse this tool identity. The question this answers is narrower: does
   the autonomous Keeper model see the schema in its tool list every turn. *)
type keeper_model_exposure = Local_runtime_tool_policy.model_exposure =
  | Keeper_callable
  | Operator_diagnostic

let keeper_model_exposure = Local_runtime_tool_policy.model_exposure
let execution_policy = Local_runtime_tool_policy.execution_policy

let definitions : definition list =
  [
    { operation = Verify; schema = {
      name = "masc_runtime_verify";
      description =
        "Admin-only contract probe for the optional typed local OpenAI-compatible runtime pool used for local benchmarks. It issues one real chat completion per selected endpoint and may load models or change warm/cache state, so it is not read-only or idempotent. An explicit runtime_pool that matches no endpoint fails closed. Returns reachability, chat-completions contract status, model match, slots, ctx, configured capacity, active slots, and local blocker codes. Missing local discovery does not assess or block official-client, CLI, or remote Keeper provider lanes.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
                  ("expected_model", `Assoc [ ("type", `String "string") ]);
                  ("expected_slots", `Assoc [ ("type", `String "integer") ]);
                  ("expected_ctx", `Assoc [ ("type", `String "integer") ]);
                ] );
          ];
    } };
    { operation = Ollama_probe; schema = {
      name = "masc_runtime_ollama_probe";
      description =
        "Admin-only native Ollama timing probe with repeated /api/generate calls. It may load a model and change warm/cache state, so it is not read-only or idempotent. Returns loaded models from /api/ps, per-run load/prompt-eval/generation timings, tok/sec estimates, and a timing-based repeated-prefix reuse inference. This does not expose direct KV occupancy or hit-rate.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("server_url", `Assoc [ ("type", `String "string") ]);
                  ("model", `Assoc [ ("type", `String "string") ]);
                  ("prompt", `Assoc [ ("type", `String "string") ]);
                  ("keep_alive", `Assoc [ ("type", `String "string") ]);
                  ("probe_runs", `Assoc [ ("type", `String "integer") ]);
                  ("max_tokens", `Assoc [ ("type", `String "integer") ]);
                  ( "think",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Boolean shorthand for think_mode. false disables reasoning-mode thinking; true enables it." );
                      ] );
                  ( "think_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "auto"; `String "disabled"; `String "enabled" ]);
                        ( "description",
                          `String
                            "Think mode choice. auto lets model decide; disabled skips reasoning; enabled forces it." );
                      ] );
                  ( "think_policy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Adaptive thinking policy for Ollama reasoning models. auto defaults to response-oriented non-thinking probes; enabled measures thinking path explicitly." );
                      ] );
                  ( "timeout_sec",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("minimum", `Int 1);
                        ( "description",
                          `String
                            "Explicit probe timeout in seconds. Every positive value is passed through unchanged." );
                      ] );
                  ("generate_when_unloaded", `Assoc [ ("type", `String "boolean") ]);
                  ("run_generate", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    } };
  ]

let schemas = List.map (fun definition -> definition.schema) definitions
