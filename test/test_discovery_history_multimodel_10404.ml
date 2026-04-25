(** #10404 — pin the discovery_history multi-model contract.

    Pre-fix [endpoint_to_record] reduced [e.models] to its head
    via [match e.models with m :: _ -> Some m.id | [] -> None].
    The ollama endpoint typically advertises 7 loaded models in
    [/api/tags], but every single probe recorded only the first
    name, so 4 days × 164 probes always reported [qwen3:8b]
    while every [cascade.toml] profile was actually driving
    [qwen3.6:27b-coding-nvfp4].

    Post-fix the writer keeps [model_id] (= primary, first
    loaded) for backward-compat readers and adds a full
    [models : string list] field so consumers can reconstruct
    the actual fleet surface.

    Tests pin:

    1. Multi-model endpoint: [models] carries every id from
       [/api/tags], not just the head.
    2. [model_id] still equals the first id for backward-compat.
    3. Empty [models] (unhealthy / not-yet-probed): [model_id]
       is [None] and [models] is the empty list.
    4. JSON shape: [models] is always emitted as an array
       (possibly empty); [model_id] only emitted when [Some]. *)

open Alcotest

module DH = Masc_mcp.Discovery_history.For_testing
module D = Llm_provider.Discovery

let mk_endpoint ~url ~models : D.endpoint_status =
  {
    url;
    healthy = true;
    models = List.map (fun id -> ({ id; owned_by = "ollama" } : D.model_info)) models;
    props = None;
    slots = None;
    capabilities = Llm_provider.Capabilities.default_capabilities;
  }

(* --- 1. multi-model preserved ------------------------------ *)

let test_models_field_carries_all_ids () =
  let ep =
    mk_endpoint
      ~url:"http://127.0.0.1:11434"
      ~models:
        [ "qwen3:8b"
        ; "qwen3.6:27b-coding-mxfp8"
        ; "qwen3.6:27b-coding-nvfp4"
        ; "qwen3.6:27b-coding-bf16"
        ; "qwen3.6:35b-a3b-mlx-bf16-64k"
        ; "supergemma4:e4b-abliterated-mlx"
        ; "qwen3.6:35b-a3b-mlx-bf16"
        ]
  in
  let r = DH.endpoint_to_record ep in
  check (list string)
    "models preserves every /api/tags id in order"
    [ "qwen3:8b"
    ; "qwen3.6:27b-coding-mxfp8"
    ; "qwen3.6:27b-coding-nvfp4"
    ; "qwen3.6:27b-coding-bf16"
    ; "qwen3.6:35b-a3b-mlx-bf16-64k"
    ; "supergemma4:e4b-abliterated-mlx"
    ; "qwen3.6:35b-a3b-mlx-bf16"
    ]
    r.models

(* --- 2. model_id stays head for back-compat --------------- *)

let test_model_id_is_first_for_backcompat () =
  let ep =
    mk_endpoint ~url:"http://x:1"
      ~models:[ "primary"; "secondary"; "tertiary" ]
  in
  let r = DH.endpoint_to_record ep in
  check (option string) "model_id == first loaded"
    (Some "primary") r.model_id

(* --- 3. empty list handled cleanly ----------------------- *)

let test_empty_models_yields_none_and_empty_list () =
  let ep = mk_endpoint ~url:"http://x:2" ~models:[] in
  let r = DH.endpoint_to_record ep in
  check (option string) "model_id None when no models"
    None r.model_id;
  check (list string) "models is the empty list" [] r.models

(* --- 4. JSON shape: models always present, model_id optional *)

let json_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let test_json_models_always_array () =
  let r =
    DH.endpoint_to_record
      (mk_endpoint ~url:"http://x:3" ~models:[ "a"; "b" ])
  in
  let j = DH.record_to_json r in
  match json_field "models" j with
  | Some (`List xs) ->
      check int "models array length" 2 (List.length xs);
      check (list string) "models array order"
        [ "a"; "b" ]
        (List.map
           (function
             | `String s -> s
             | _ -> failwith "expected string")
           xs)
  | _ -> failf "models field absent or wrong type"

let test_json_models_empty_array_when_no_models () =
  let r =
    DH.endpoint_to_record (mk_endpoint ~url:"http://x:4" ~models:[])
  in
  let j = DH.record_to_json r in
  (match json_field "models" j with
   | Some (`List []) -> ()
   | Some _ -> failf "models field present but not empty list"
   | None -> failf "models field missing on empty-models endpoint");
  check bool "model_id absent from JSON when None" false
    (Option.is_some (json_field "model_id" j))

let () =
  run "discovery_history_multimodel_10404"
    [
      ( "models-preserved",
        [
          test_case "all /api/tags ids in order" `Quick
            test_models_field_carries_all_ids;
          test_case "model_id == first for back-compat" `Quick
            test_model_id_is_first_for_backcompat;
          test_case "empty list yields None + []" `Quick
            test_empty_models_yields_none_and_empty_list;
        ] );
      ( "json-shape",
        [
          test_case "models always emitted as array" `Quick
            test_json_models_always_array;
          test_case "models is empty array when no models" `Quick
            test_json_models_empty_array_when_no_models;
        ] );
    ]
