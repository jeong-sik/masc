(** Routing policy unit tests.

    Validates task_use categories, legacy mapping,
    default policies, model resolution, and diversity constraints. *)

open Alcotest
open Masc_mcp.Cascade_phonebook_types
open Masc_mcp.Cascade_routing_policy

let task_use_of_string_exn (s : string) : task_use =
  match task_use_of_string s with
  | Some t -> t
  | None -> failwith ("unknown task_use: " ^ s)

(* --- task_use roundtrip --- *)

let test_roundtrip () =
  let all =
    [ Code_generation; Code_review; Quick_decision
    ; Long_reasoning; Tool_execution; Conversation
    ]
  in
  List.iter
    (fun t ->
       let s = task_use_to_string t in
       check (option string) "roundtrip"
         (Some s)
         (Option.map task_use_to_string (task_use_of_string s)))
    all

let test_unknown_is_none () =
  check (option string) "unknown" None
    (Option.map task_use_to_string (task_use_of_string "nonexistent"))

(* --- Legacy logical_use mapping --- *)

let unwrap = function Some x -> x | None -> failwith "unexpected None"

let test_legacy_keeper_turn () =
  check string "keeper_turn → Code_generation"
    "code_generation"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "keeper_turn")))

let test_legacy_tool_required () =
  check string "tool_required → Tool_execution"
    "tool_execution"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "tool_required")))

let test_legacy_adversarial_reviewer () =
  check string "adversarial_reviewer → Code_review"
    "code_review"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "adversarial_reviewer")))

let test_legacy_cross_verifier () =
  check string "cross_verifier → Code_review"
    "code_review"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "cross_verifier")))

let test_legacy_auto_responder () =
  check string "auto_responder → Quick_decision"
    "quick_decision"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "auto_responder")))

let test_legacy_complex_task () =
  check string "complex_task → Long_reasoning"
    "long_reasoning"
    (task_use_to_string (unwrap (task_use_of_legacy_logical_use "complex_task")))

let test_legacy_unknown () =
  check (option string) "unknown → None"
    None
    (Option.map task_use_to_string (task_use_of_legacy_logical_use "something_new"))

(* --- Default routing policies --- *)

let test_policy_count () =
  check int "6 policies" 6 (List.length default_routing_policies)

let test_code_generation_policy () =
  match policy_for_task default_routing_policies Code_generation with
  | None -> failwith "no policy for Code_generation"
  | Some p ->
    check string "primary_tier_group" "primary" p.primary_tier_group;
    check (option string) "no diversity" None
      (Option.map (fun (_ : diversity_constraint) -> "has diversity") p.diversity)

let test_code_review_policy () =
  match policy_for_task default_routing_policies Code_review with
  | None -> failwith "no policy for Code_review"
  | Some p ->
    check string "primary_tier_group" "cross-verify" p.primary_tier_group;
    check bool "has diversity" true
      (match p.diversity with Some Diverse_from_primary -> true | _ -> false)

let test_all_tasks_have_policies () =
  let all =
    [ Code_generation; Code_review; Quick_decision
    ; Long_reasoning; Tool_execution; Conversation
    ]
  in
  List.iter
    (fun t ->
       check (option string) (task_use_to_string t ^ " has policy")
         (Some "yes")
         (Option.map (fun (_ : task_routing_policy) -> "yes")
            (policy_for_task default_routing_policies t)))
    all

(* --- Test phonebook fixture --- *)

let test_pb : cascade_phonebook =
  let toml =
    {|[defaults]
max_output_tokens = 4096
default_thinking_budget = 8192

[providers.runpod-llama]
endpoint = "https://example.com/v1"
protocol = "openai-http"
flavor = "llama-cpp"

[providers.zai-glm-api]
endpoint = "https://open.bigmodel.cn/api/paas/v4"
protocol = "openai-http"
flavor = "zai-glm"

[providers.deepseek-cloud]
endpoint = "https://api.deepseek.com"
protocol = "openai-http"
flavor = "deepseek"

[models.qwen3-235b]
provider = "runpod-llama"
model_id = "qwen3-235b-a22b"

[models.glm-5]
provider = "zai-glm-api"
model_id = "glm-5"

[models.deepseek-v4-flash]
provider = "deepseek-cloud"
model_id = "deepseek-v4-flash"

[tier-groups.primary]
members = ["qwen3-235b"]
weight = 100

[tier-groups.cross-verify]
members = ["glm-5", "deepseek-v4-flash"]
constraint = "diverse_from_primary"
|}
  in
  let parsed = Otoml.Parser.from_string toml in
  match Masc_mcp.Cascade_phonebook_parser.parse_phonebook parsed with
  | Ok pb -> pb
  | Error errs ->
    failwith
      ("test fixture parse error: "
       ^ String.concat "; " (List.map (fun (e : Masc_mcp.Cascade_phonebook_parser.parse_error) -> e.path ^ ": " ^ e.message) errs))

(* --- Model resolution --- *)

let test_resolve_code_generation () =
  let models = resolve_models_for_task test_pb default_routing_policies Code_generation in
  check int "1 model" 1 (List.length models);
  match models with
  | [] -> failwith "no models"
  | m :: _ -> check string "qwen3-235b" "qwen3-235b" m.id

let test_resolve_code_review () =
  let models = resolve_models_for_task test_pb default_routing_policies Code_review in
  check int "2 models in cross-verify" 2 (List.length models)

let test_resolve_unknown_tier_group () =
  let bad_policy =
    [ { task = Code_generation; primary_tier_group = "nonexistent"; diversity = None } ]
  in
  let models = resolve_models_for_task test_pb bad_policy Code_generation in
  check int "0 models for nonexistent tier-group" 0 (List.length models)

(* --- Diversity constraints --- *)

let test_satisfies_no_constraint () =
  let primary_tg =
    match tier_group_of_name test_pb "primary" with
    | Some tg -> tg
    | None -> failwith "primary not found"
  in
  match model_of_id test_pb "glm-5" with
  | None -> failwith "model not found"
  | Some candidate ->
    check bool "any available" true (satisfies_diversity test_pb primary_tg None candidate)

let test_satisfies_diverse_from_primary () =
  let primary_tg =
    match tier_group_of_name test_pb "primary" with
    | Some tg -> tg
    | None -> failwith "primary not found"
  in
  (match model_of_id test_pb "glm-5" with
   | None -> failwith "glm-5 not found"
   | Some candidate ->
     check bool "glm-5 is diverse from primary runpod"
       true
       (satisfies_diversity test_pb primary_tg (Some Diverse_from_primary) candidate));
  (match model_of_id test_pb "qwen3-235b" with
   | None -> failwith "qwen3-235b not found"
   | Some candidate ->
     check bool "qwen3-235b is NOT diverse from primary"
       false
       (satisfies_diversity test_pb primary_tg (Some Diverse_from_primary) candidate))

let test_satisfies_same_provider () =
  let primary_tg =
    match tier_group_of_name test_pb "primary" with
    | Some tg -> tg
    | None -> failwith "primary not found"
  in
  (match model_of_id test_pb "qwen3-235b" with
   | None -> failwith "qwen3-235b not found"
   | Some candidate ->
     check bool "qwen3-235b same provider as primary"
       true
       (satisfies_diversity test_pb primary_tg (Some Same_provider) candidate));
  (match model_of_id test_pb "glm-5" with
   | None -> failwith "glm-5 not found"
   | Some candidate ->
     check bool "glm-5 NOT same provider as primary"
       false
       (satisfies_diversity test_pb primary_tg (Some Same_provider) candidate))

(* --- Suite --- *)

let () =
  run "Cascade Routing Policy"
    [ ( "task_use"
      , [ test_case "roundtrip" `Quick test_roundtrip
        ; test_case "unknown is None" `Quick test_unknown_is_none
        ] )
    ; ( "legacy_mapping"
      , [ test_case "keeper_turn" `Quick test_legacy_keeper_turn
        ; test_case "tool_required" `Quick test_legacy_tool_required
        ; test_case "adversarial_reviewer" `Quick test_legacy_adversarial_reviewer
        ; test_case "cross_verifier" `Quick test_legacy_cross_verifier
        ; test_case "auto_responder" `Quick test_legacy_auto_responder
        ; test_case "complex_task" `Quick test_legacy_complex_task
        ; test_case "unknown → Conversation" `Quick test_legacy_unknown
        ] )
    ; ( "default_policies"
      , [ test_case "count" `Quick test_policy_count
        ; test_case "code_generation" `Quick test_code_generation_policy
        ; test_case "code_review" `Quick test_code_review_policy
        ; test_case "all covered" `Quick test_all_tasks_have_policies
        ] )
    ; ( "resolution"
      , [ test_case "code_generation → primary" `Quick test_resolve_code_generation
        ; test_case "code_review → cross-verify" `Quick test_resolve_code_review
        ; test_case "nonexistent tier-group → empty" `Quick test_resolve_unknown_tier_group
        ] )
    ; ( "diversity"
      , [ test_case "no constraint" `Quick test_satisfies_no_constraint
        ; test_case "diverse_from_primary" `Quick test_satisfies_diverse_from_primary
        ; test_case "same_provider" `Quick test_satisfies_same_provider
        ] )
    ]
