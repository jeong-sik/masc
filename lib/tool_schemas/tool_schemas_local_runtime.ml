(** Tool_schemas_local_runtime — SSOT for local-runtime tool schemas. *)

open Masc_domain

type operation =
  | Verify
  | Ollama_probe

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

let operation_id = function
  | Verify -> "verify"
  | Ollama_probe -> "ollama_probe"
;;

let definitions : definition list =
  [
    { operation = Verify; schema = {
      name = "masc_runtime_verify";
      description =
        "Strictly verify the active provider/runtime contract used for swarm and benchmark runs. Returns reachability, chat-completions contract status, model match, slots, ctx, configured capacity, active slots, and blocker codes such as provider_unreachable, provider_model_mismatch, slot_count_insufficient, ctx_mismatch, or chat_contract_incompatible.";
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
        "Probe native Ollama timing behavior with repeated /api/generate calls. Returns loaded models from /api/ps, per-run load/prompt-eval/generation timings, tok/sec estimates, and a timing-based repeated-prefix reuse inference. This does not expose direct KV occupancy or hit-rate.";
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
                  ("timeout_sec", `Assoc [ ("type", `String "integer") ]);
                  ("generate_when_unloaded", `Assoc [ ("type", `String "boolean") ]);
                  ("run_generate", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    } };
  ]

let schemas = List.map (fun definition -> definition.schema) definitions
