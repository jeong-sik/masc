(** Phonebook integration tests.

    End-to-end: TOML file → phonebook parser → routing policy → model resolution.
    Uses the real cascade-phonebook.toml fixture. *)

open Alcotest
open Masc_mcp.Cascade_phonebook_types
open Masc_mcp.Cascade_phonebook_parser
open Masc_mcp.Cascade_routing_policy
open Masc_mcp.Cascade_server_flavor

let phonebook_toml_path = ".masc/config/cascade-phonebook.toml"

let ok_phonebook (result : (cascade_phonebook, parse_error list) result) =
  match result with
  | Ok pb -> pb
  | Error errs ->
    let msg =
      List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs
      |> String.concat "; "
    in
    failwith ("expected Ok, got Error: " ^ msg)

let load_fixture () =
  let toml = Otoml.Parser.from_file phonebook_toml_path in
  ok_phonebook (parse_phonebook toml)

(* --- Routing policy end-to-end --- *)

let test_code_generation_routes_to_primary () =
  let pb = load_fixture () in
  let models = resolve_models_for_task pb default_routing_policies Code_generation in
  check bool "at least 1 model" true (List.length models >= 1);
  match models with
  | [] -> failwith "no models"
  | m :: _ ->
    check string "primary model" "qwen3-235b" m.id;
    check string "provider" "runpod-llama" m.provider

let test_code_review_routes_cross_verify () =
  let pb = load_fixture () in
  let models = resolve_models_for_task pb default_routing_policies Code_review in
  check bool "at least 2 models" true (List.length models >= 2);
  let primary_tg =
    match tier_group_of_name pb "primary" with
    | Some tg -> tg
    | None -> failwith "primary tier-group not found"
  in
  List.iter (fun m ->
    check bool (Printf.sprintf "%s is diverse from primary" m.id)
      true (satisfies_diversity pb primary_tg (Some Diverse_from_primary) m)
  ) models

let test_quick_decision_routes_fast () =
  let pb = load_fixture () in
  let models = resolve_models_for_task pb default_routing_policies Quick_decision in
  check bool "at least 1 model" true (List.length models >= 1)

let test_conversation_routes_primary () =
  let pb = load_fixture () in
  let models = resolve_models_for_task pb default_routing_policies Conversation in
  check bool "at least 1 model" true (List.length models >= 1)

(* --- Flavor integration --- *)

(* cascade_server_flavor.ml shares the type via
   "type t = Cascade_phonebook_types.t = ...", so no conversion needed. *)
let flavor_of_phonebook (f : cascade_server_flavor) : cascade_server_flavor = f

let test_model_flavor_lookup () =
  let pb = load_fixture () in
  (match model_of_id pb "qwen3-235b" with
   | None -> failwith "qwen3-235b not found"
   | Some m ->
     match provider_of_model pb m with
     | None -> failwith "provider not found"
     | Some p ->
       check string "flavor" "llama-cpp" (flavor_to_string p.flavor);
       check bool "can stream with tools" true
         (can_stream_with_tools (flavor_of_phonebook p.flavor)));
  (match model_of_id pb "deepseek-v4-flash" with
   | None -> failwith "deepseek-v4-flash not found"
   | Some m ->
     match provider_of_model pb m with
     | None -> failwith "provider not found"
     | Some p ->
       check string "flavor" "deepseek" (flavor_to_string p.flavor));
  (match model_of_id pb "qwen3-5-plus" with
   | None -> failwith "qwen3-5-plus not found"
   | Some m ->
     match provider_of_model pb m with
     | None -> failwith "provider not found"
     | Some p ->
       check string "flavor" "qwen" (flavor_to_string p.flavor);
       check bool "Qwen cannot stream with tools" false
         (can_stream_with_tools (flavor_of_phonebook p.flavor)))

let test_thinking_control_per_model () =
  let pb = load_fixture () in
  (* llama-cpp: extended thinking with chat_template_kwargs *)
  (match model_of_id pb "qwen3-235b" with
   | Some m ->
     check bool "supports_extended_thinking" true m.capabilities.supports_extended_thinking;
     check bool "format is Chat_template_kwargs"
       true (m.capabilities.thinking_control_format = Chat_template_kwargs)
   | None -> failwith "qwen3-235b not found");
  (* zai-glm: extended thinking with reasoning_content *)
  (match model_of_id pb "glm-5" with
   | Some m ->
     check bool "supports_extended_thinking" true m.capabilities.supports_extended_thinking;
     check bool "format is Reasoning_content"
       true (m.capabilities.thinking_control_format = Reasoning_content)
   | None -> failwith "glm-5 not found");
  (* deepseek: extended thinking with reasoning_param *)
  (match model_of_id pb "deepseek-v4-flash" with
   | Some m ->
     check bool "supports_extended_thinking" true m.capabilities.supports_extended_thinking;
     check bool "format is Reasoning_param"
       true (m.capabilities.thinking_control_format = Reasoning_param)
   | None -> failwith "deepseek-v4-flash not found");
  (* openai: reasoning budget *)
  (match model_of_id pb "o3-mini" with
   | Some m ->
     check bool "supports_reasoning_budget" true m.capabilities.supports_reasoning_budget;
     check bool "format is Reasoning_effort"
       true (m.capabilities.thinking_control_format = Reasoning_effort)
   | None -> failwith "o3-mini not found")

let test_fast_tier_group_no_thinking () =
  let pb = load_fixture () in
  match tier_group_of_name pb "fast" with
  | None -> failwith "fast tier-group not found"
  | Some tg ->
    let models = models_of_tier_group pb tg in
    List.iter (fun m ->
      check bool (Printf.sprintf "%s: no extended thinking" m.id)
        false m.capabilities.supports_extended_thinking
    ) models

(* --- Legacy mapping integration --- *)

let test_legacy_logical_use_to_phonebook_route () =
  let pb = load_fixture () in
  let keeper_turn = task_use_of_legacy_logical_use "keeper_turn" in
  let models = resolve_models_for_task pb default_routing_policies keeper_turn in
  check bool "keeper_turn → at least 1 model" true (List.length models >= 1);
  let adversarial = task_use_of_legacy_logical_use "adversarial_reviewer" in
  let adv_models = resolve_models_for_task pb default_routing_policies adversarial in
  check bool "adversarial_reviewer → at least 1 model" true (List.length adv_models >= 1)

(* --- Tier-group completeness --- *)

let test_all_tier_groups_resolve () =
  let pb = load_fixture () in
  let all_tg_names = ["primary"; "cross-verify"; "coding-verify"; "fast"; "coding"] in
  List.iter (fun name ->
    match tier_group_of_name pb name with
    | None -> failwith (Printf.sprintf "tier-group '%s' not found" name)
    | Some tg ->
      let models = models_of_tier_group pb tg in
      check int (Printf.sprintf "%s has members" name)
        (List.length tg.members) (List.length models)
  ) all_tg_names

let test_coding_verify_diverse () =
  let pb = load_fixture () in
  match tier_group_of_name pb "coding-verify" with
  | None -> failwith "coding-verify not found"
  | Some tg ->
    check bool "has Diverse_from_primary constraint"
      true (tg.constraint_ = Some Diverse_from_primary);
    let models = models_of_tier_group pb tg in
    let primary_tg =
      match tier_group_of_name pb "primary" with
      | Some t -> t
      | None -> failwith "primary not found"
    in
    List.iter (fun m ->
      check bool (Printf.sprintf "%s is diverse from primary" m.id)
        true (satisfies_diversity pb primary_tg (Some Diverse_from_primary) m)
    ) models

(* --- Suite --- *)

let () =
  run "Cascade Phonebook Integration"
    [ ( "routing_e2e"
      , [ test_case "code_generation → primary" `Quick test_code_generation_routes_to_primary
        ; test_case "code_review → cross-verify diverse" `Quick test_code_review_routes_cross_verify
        ; test_case "quick_decision → fast" `Quick test_quick_decision_routes_fast
        ; test_case "conversation → primary" `Quick test_conversation_routes_primary
        ] )
    ; ( "flavor_e2e"
      , [ test_case "model → provider → flavor" `Quick test_model_flavor_lookup
        ; test_case "thinking control per model" `Quick test_thinking_control_per_model
        ; test_case "fast tier no extended thinking" `Quick test_fast_tier_group_no_thinking
        ] )
    ; ( "legacy_compat"
      , [ test_case "legacy logical_use routes" `Quick test_legacy_logical_use_to_phonebook_route
        ] )
    ; ( "tier_group_completeness"
      , [ test_case "all tier-groups resolve" `Quick test_all_tier_groups_resolve
        ; test_case "coding-verify diverse from primary" `Quick test_coding_verify_diverse
        ] )
    ]
