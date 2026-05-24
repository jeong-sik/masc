(** Phonebook parser + types unit tests.

    Validates TOML parsing into typed phonebook,
    including lookup helpers and error accumulation. *)

open Alcotest
open Masc_mcp.Cascade_phonebook_types
open Masc_mcp.Cascade_phonebook_parser

(* --- Helpers --- *)

let ok_phonebook
    (result : (cascade_phonebook, parse_error list) result)
    : cascade_phonebook =
  match result with
  | Ok pb -> pb
  | Error errs ->
    let msg =
      List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs
      |> String.concat "; "
    in
    failwith ("expected Ok, got Error: " ^ msg)

let is_error
    (result : (cascade_phonebook, parse_error list) result)
    : parse_error list =
  match result with
  | Ok _ -> failwith "expected Error, got Ok"
  | Error errs -> errs

let has_error_at (path : string) (errs : parse_error list) =
  check bool ("error at " ^ path) true (List.exists (fun e -> e.path = path) errs)

(* --- Test TOML fixtures --- *)

let minimal_toml =
  {|[defaults]
max_output_tokens = 4096
default_thinking_budget = 8192

[providers.runpod-llama]
endpoint = "https://example.com/v1"
protocol = "openai-http"
flavor = "llama-cpp"
auth_env = "RUNPOD_API_TOKEN"

[models.qwen3-235b]
provider = "runpod-llama"
model_id = "qwen3-235b-a22b"

[tier-groups.primary]
members = ["qwen3-235b"]
weight = 100
|}

let full_toml =
  {|[defaults]
max_output_tokens = 8192
default_thinking_budget = 16384

[providers.runpod-llama]
endpoint = "https://ma8xbr1kgbclkl-19123.proxy.runpod.net/v1"
protocol = "openai-http"
flavor = "llama-cpp"
auth_env = "RUNPOD_API_TOKEN"

[providers.zai-glm-api]
endpoint = "https://open.bigmodel.cn/api/paas/v4"
protocol = "openai-http"
flavor = "zai-glm"
auth_env = "ZAI_API_KEY"

[providers.deepseek-cloud]
endpoint = "https://api.deepseek.com"
protocol = "openai-http"
flavor = "deepseek"
auth_env = "DEEPSEEK_API_KEY"

[models.qwen3-235b]
provider = "runpod-llama"
model_id = "qwen3-235b-a22b"
capabilities = { max_output_tokens = 32768, supports_tool_choice = true, supports_extended_thinking = true, thinking_control_format = "chat_template_kwargs", supports_image_input = true }

[models.glm-5]
provider = "zai-glm-api"
model_id = "glm-5"
capabilities = { max_output_tokens = 16384, supports_tool_choice = true, supports_extended_thinking = true, thinking_control_format = "reasoning_content" }

[models.deepseek-v4-flash]
provider = "deepseek-cloud"
model_id = "deepseek-v4-flash"
capabilities = { max_output_tokens = 65536, supports_tool_choice = true, supports_extended_thinking = true, thinking_control_format = "reasoning_param" }

[tier-groups.primary]
members = ["qwen3-235b"]
weight = 100

[tier-groups.cross-verify]
members = ["glm-5", "deepseek-v4-flash"]
constraint = "diverse_from_primary"
|}

let parse_toml (s : string) : (cascade_phonebook, parse_error list) result =
  let toml = Otoml.Parser.from_string s in
  parse_phonebook toml

(* --- Defaults tests --- *)

let test_defaults_minimal () =
  let pb = ok_phonebook (parse_toml minimal_toml) in
  check int "max_output_tokens" 4096 pb.defaults.max_output_tokens;
  check int "default_thinking_budget" 8192 pb.defaults.default_thinking_budget

let test_defaults_full () =
  let pb = ok_phonebook (parse_toml full_toml) in
  check int "max_output_tokens" 8192 pb.defaults.max_output_tokens;
  check int "default_thinking_budget" 16384 pb.defaults.default_thinking_budget

let test_defaults_missing () =
  let toml = {|[providers.x]
endpoint = "https://example.com"
protocol = "openai-http"
flavor = "openai"
|}
  in
  let pb = ok_phonebook (parse_toml toml) in
  check int "max_output_tokens default" 4096 pb.defaults.max_output_tokens;
  check int "default_thinking_budget default" 8192 pb.defaults.default_thinking_budget

(* --- Provider tests --- *)

let test_provider_count () =
  let pb = ok_phonebook (parse_toml full_toml) in
  check int "provider count" 3 (List.length pb.providers)

let test_provider_fields () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match provider_of_id pb "runpod-llama" with
  | None -> failwith "provider runpod-llama not found"
  | Some p ->
    check string "id" "runpod-llama" p.id;
    check string "endpoint" "https://ma8xbr1kgbclkl-19123.proxy.runpod.net/v1" p.endpoint;
    check string "protocol" "openai-http" (protocol_to_string p.protocol);
    check string "flavor" "llama-cpp" (flavor_to_string p.flavor);
    check (option string) "auth_env" (Some "RUNPOD_API_TOKEN") p.auth_env

let test_provider_missing_endpoint () =
  let toml = {|[providers.broken]
protocol = "openai-http"
flavor = "openai"
|}
  in
  let errs = is_error (parse_toml toml) in
  has_error_at "providers.broken.endpoint" errs

(* --- Model tests --- *)

let test_model_count () =
  let pb = ok_phonebook (parse_toml full_toml) in
  check int "model count" 3 (List.length pb.models)

let test_model_fields () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "qwen3-235b" with
  | None -> failwith "model qwen3-235b not found"
  | Some m ->
    check string "id" "qwen3-235b" m.id;
    check string "provider" "runpod-llama" m.provider;
    check string "model_id" "qwen3-235b-a22b" m.model_id

let test_model_capabilities () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "qwen3-235b" with
  | None -> failwith "model not found"
  | Some m ->
    check (option int) "max_output_tokens" (Some 32768) m.capabilities.max_output_tokens;
    check bool "supports_tool_choice" true m.capabilities.supports_tool_choice;
    check bool "supports_extended_thinking" true m.capabilities.supports_extended_thinking;
    check bool "supports_image_input" true m.capabilities.supports_image_input

let test_model_missing_provider () =
  let toml = {|[models.broken]
model_id = "test"
|}
  in
  let errs = is_error (parse_toml toml) in
  has_error_at "models.broken.provider" errs

let test_model_missing_model_id () =
  let toml = {|[models.broken]
provider = "x"
|}
  in
  let errs = is_error (parse_toml toml) in
  has_error_at "models.broken.model_id" errs

(* --- Tier-group tests --- *)

let test_tier_group_count () =
  let pb = ok_phonebook (parse_toml full_toml) in
  check int "tier_group count" 2 (List.length pb.tier_groups)

let test_tier_group_primary () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match tier_group_of_name pb "primary" with
  | None -> failwith "tier-group primary not found"
  | Some tg ->
    check string "name" "primary" tg.name;
    check int "weight" 100 tg.weight;
    check int "members length" 1 (List.length tg.members);
    check bool "no constraint" true (tg.constraint_ = None)

let test_tier_group_cross_verify () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match tier_group_of_name pb "cross-verify" with
  | None -> failwith "tier-group cross-verify not found"
  | Some tg ->
    check int "members length" 2 (List.length tg.members);
    check bool "constraint is Diverse_from_primary"
      true
      (tg.constraint_ = Some Diverse_from_primary)

let test_tier_group_missing_members () =
  let toml = {|[tier-groups.broken]
weight = 50
|}
  in
  let errs = is_error (parse_toml toml) in
  has_error_at "tier-groups.broken.members" errs

(* --- Lookup helpers --- *)

let test_models_of_tier_group () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match tier_group_of_name pb "primary" with
  | None -> failwith "tier-group not found"
  | Some tg ->
    let models = models_of_tier_group pb tg in
    check int "models in primary" 1 (List.length models);
    match models with
    | [] -> failwith "no models"
    | m :: _ -> check string "model id" "qwen3-235b" m.id

let test_provider_of_model () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "glm-5" with
  | None -> failwith "model glm-5 not found"
  | Some m ->
    match provider_of_model pb m with
    | None -> failwith "provider not found"
    | Some p -> check string "provider id" "zai-glm-api" p.id

(* --- Thinking control format --- *)

let test_thinking_format_chat_template_kwargs () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "qwen3-235b" with
  | None -> failwith "model not found"
  | Some m ->
    check bool "is Chat_template_kwargs"
      true
      (m.capabilities.thinking_control_format = Chat_template_kwargs)

let test_thinking_format_reasoning_content () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "glm-5" with
  | None -> failwith "model not found"
  | Some m ->
    check bool "is Reasoning_content"
      true
      (m.capabilities.thinking_control_format = Reasoning_content)

let test_thinking_format_thinking_param () =
  let pb = ok_phonebook (parse_toml full_toml) in
  match model_of_id pb "deepseek-v4-flash" with
  | None -> failwith "model not found"
  | Some m ->
    check bool "is Reasoning_param"
      true
      (m.capabilities.thinking_control_format = Reasoning_param)

(* --- Real TOML file validation --- *)

let phonebook_toml_path = "test/fixtures/cascade-phonebook.toml"

let test_real_toml_parses () =
  let toml = Otoml.Parser.from_file phonebook_toml_path in
  let pb = ok_phonebook (parse_phonebook toml) in
  check int "8 providers" 8 (List.length pb.providers);
  check int "10 models" 10 (List.length pb.models);
  check int "5 tier-groups" 5 (List.length pb.tier_groups)

let test_real_toml_tier_groups () =
  let toml = Otoml.Parser.from_file phonebook_toml_path in
  let pb = ok_phonebook (parse_phonebook toml) in
  let names = List.map (fun (tg : cascade_phonebook_tier_group) -> tg.name) pb.tier_groups
              |> List.sort String.compare in
  check (list string) "tier-group names"
    ["coding"; "coding-verify"; "cross-verify"; "fast"; "primary"] names

let test_real_toml_cross_verify_diverse () =
  let toml = Otoml.Parser.from_file phonebook_toml_path in
  let pb = ok_phonebook (parse_phonebook toml) in
  match tier_group_of_name pb "cross-verify" with
  | None -> failwith "cross-verify not found"
  | Some tg ->
    check int "3 members" 3 (List.length tg.members);
    check bool "has Diverse_from_primary constraint"
      true (tg.constraint_ = Some Diverse_from_primary)

let test_real_toml_model_capabilities () =
  let toml = Otoml.Parser.from_file phonebook_toml_path in
  let pb = ok_phonebook (parse_phonebook toml) in
  (match model_of_id pb "qwen3-235b" with
   | None -> failwith "qwen3-235b not found"
   | Some m ->
     check (option int) "max_output_tokens" (Some 32768) m.capabilities.max_output_tokens;
     check bool "supports_extended_thinking" true m.capabilities.supports_extended_thinking;
     check bool "supports_image_input" true m.capabilities.supports_image_input);
  (match model_of_id pb "glm-4-7-flash" with
   | None -> failwith "glm-4-7-flash not found"
   | Some m ->
     check bool "no extended thinking" false m.capabilities.supports_extended_thinking)

(* --- Suite --- *)

let () =
  run "Cascade Phonebook"
    [ ( "defaults"
      , [ test_case "minimal" `Quick test_defaults_minimal
        ; test_case "full" `Quick test_defaults_full
        ; test_case "missing uses defaults" `Quick test_defaults_missing
        ] )
    ; ( "providers"
      , [ test_case "count" `Quick test_provider_count
        ; test_case "fields" `Quick test_provider_fields
        ; test_case "missing endpoint errors" `Quick test_provider_missing_endpoint
        ] )
    ; ( "models"
      , [ test_case "count" `Quick test_model_count
        ; test_case "fields" `Quick test_model_fields
        ; test_case "capabilities" `Quick test_model_capabilities
        ; test_case "missing provider errors" `Quick test_model_missing_provider
        ; test_case "missing model_id errors" `Quick test_model_missing_model_id
        ] )
    ; ( "tier-groups"
      , [ test_case "count" `Quick test_tier_group_count
        ; test_case "primary" `Quick test_tier_group_primary
        ; test_case "cross-verify" `Quick test_tier_group_cross_verify
        ; test_case "missing members errors" `Quick test_tier_group_missing_members
        ] )
    ; ( "lookups"
      , [ test_case "models_of_tier_group" `Quick test_models_of_tier_group
        ; test_case "provider_of_model" `Quick test_provider_of_model
        ] )
    ; ( "thinking_format"
      , [ test_case "chat_template_kwargs" `Quick test_thinking_format_chat_template_kwargs
        ; test_case "reasoning_content" `Quick test_thinking_format_reasoning_content
        ; test_case "thinking_param" `Quick test_thinking_format_thinking_param
        ] )
    ; ( "real_toml"
      , [ test_case "parses" `Quick test_real_toml_parses
        ; test_case "tier_groups" `Quick test_real_toml_tier_groups
        ; test_case "cross_verify_diverse" `Quick test_real_toml_cross_verify_diverse
        ; test_case "model_capabilities" `Quick test_real_toml_model_capabilities
        ] )
    ]
