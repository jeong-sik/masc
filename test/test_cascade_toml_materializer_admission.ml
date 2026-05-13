(** Regression test for cascade_toml_materializer admission namespace
    pass-through.

    Without the special-case [admission] handling in
    [render_toml_to_yojson], a TOML with [admission.<keeper>] sub-tables
    fails the materializer with "unknown field <keeper> in profile
    admission" — bringing down every keeper that resolves a cascade
    through cascade.toml, not just the keepers with admission blocks.

    Live regression observed 2026-05-05 02:55 UTC: appending RFC-0026
    [admission.*] blocks to live cascade.toml triggered fleet-wide
    materialize failure → all 5 watchdog-killed keepers had idle stalls
    302-314s. *)

open Masc_mcp

let render content =
  Cascade_toml_materializer.render_toml_string_to_json_string content

let parse_json_string (s : string) : Yojson.Safe.t =
  Yojson.Safe.from_string s

let test_admission_namespace_passthrough () =
  let toml =
    {|
[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.glm-auto]
api-name = "auto"
max-context = 128000
tools-support = true
streaming = true

[glm-coding.glm-auto]
is-default = true
max-concurrent = 2

[tier.coding_plan]
members = ["glm-coding.glm-auto"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.coding_plan"

[admission.analyst]
weight = 1
min_tier = "Preferred"
candidates = [
  { provider = "anthropic", model = "claude_code:auto", tier = "Preferred" },
  { provider = "openai", model = "codex_cli:gpt-5", tier = "Acceptable" },
]
|}
  in
  match render toml with
  | Error msg ->
      Alcotest.failf "render failed: %s" msg
  | Ok json_str ->
      let json = parse_json_string json_str in
      (match json with
       | `Assoc fields ->
           let admission = List.assoc_opt "admission" fields in
           Alcotest.(check bool)
             "admission key present at top level"
             true (Option.is_some admission);
           (match admission with
            | Some (`Assoc admission_fields) ->
                let analyst = List.assoc_opt "analyst" admission_fields in
                Alcotest.(check bool)
                  "admission.analyst sub-table present"
                  true (Option.is_some analyst);
                (match analyst with
                 | Some (`Assoc analyst_fields) ->
                     Alcotest.(check bool)
                       "analyst has weight"
                       true (List.mem_assoc "weight" analyst_fields);
                     Alcotest.(check bool)
                       "analyst has min_tier"
                       true (List.mem_assoc "min_tier" analyst_fields);
                     Alcotest.(check bool)
                       "analyst has candidates"
                       true (List.mem_assoc "candidates" analyst_fields)
                 | _ -> Alcotest.fail "analyst should be an object")
            | _ -> Alcotest.fail "admission should be an object")
       | _ -> Alcotest.fail "top level should be an object")

let test_admission_with_no_blocks_still_renders () =
  (* Sanity: removing the admission namespace shouldn't break the
     materializer; existing cascade.toml without admission blocks must
     still render cleanly. *)
  let toml =
    {|
[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.glm-auto]
api-name = "auto"
max-context = 128000
tools-support = true
streaming = true

[glm-coding.glm-auto]
is-default = true
max-concurrent = 2

[tier.coding_plan]
members = ["glm-coding.glm-auto"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.coding_plan"
|}
  in
  match render toml with
  | Error msg -> Alcotest.failf "render failed: %s" msg
  | Ok _ -> ()

let test_admission_candidates_array_preserved () =
  (* Each candidate should be a JSON object with provider/model/tier
     fields — the schema [Keeper_admission_policy.parse_admission_json]
     reads. *)
  let toml =
    {|
[admission.executor]
weight = 2
min_tier = "Acceptable"
candidates = [
  { provider = "anthropic", model = "m1", tier = "Preferred" },
  { provider = "openai", model = "m2", tier = "Acceptable" },
  { provider = "ollama", model = "m3", tier = "Survival" },
]
|}
  in
  match render toml with
  | Error msg -> Alcotest.failf "render failed: %s" msg
  | Ok json_str ->
      let json = parse_json_string json_str in
      let candidates =
        match json with
        | `Assoc fields ->
            (match List.assoc_opt "admission" fields with
             | Some (`Assoc adm) ->
                 (match List.assoc_opt "executor" adm with
                  | Some (`Assoc ex) -> List.assoc_opt "candidates" ex
                  | _ -> None)
             | _ -> None)
        | _ -> None
      in
      match candidates with
      | Some (`List rows) ->
          Alcotest.(check int) "3 candidates" 3 (List.length rows);
          (match List.hd rows with
           | `Assoc r ->
               Alcotest.(check (option pass)) "provider"
                 (Some (`String "anthropic"))
                 (List.assoc_opt "provider" r);
               Alcotest.(check (option pass)) "tier"
                 (Some (`String "Preferred"))
                 (List.assoc_opt "tier" r)
           | _ -> Alcotest.fail "candidate should be object")
      | _ -> Alcotest.fail "candidates should be a JSON list"

let () =
  Alcotest.run "cascade_toml_materializer_admission"
    [
      ( "admission_passthrough",
        [
          Alcotest.test_case
            "admission.<keeper> sub-table renders to JSON without unknown-field error"
            `Quick test_admission_namespace_passthrough;
          Alcotest.test_case
            "candidates array preserves provider/model/tier"
            `Quick test_admission_candidates_array_preserved;
          Alcotest.test_case
            "no admission blocks still renders cleanly (regression guard)"
            `Quick test_admission_with_no_blocks_still_renders;
        ] );
    ]
