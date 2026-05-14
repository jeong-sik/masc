open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module KT = Masc_mcp.Keeper_types

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let with_worktree_config_root f =
  let cwd = Sys.getcwd () in
  let config_dir = Filename.concat cwd "config" in
  let prev_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let prev_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" prev_config_dir;
      restore_env "MASC_BASE_PATH" prev_base_path;
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Unix.putenv "MASC_BASE_PATH" "";
      Masc_mcp.Config_dir_resolver.reset ();
      f ())

let labels_for_turn meta =
  with_worktree_config_root @@ fun () ->
  Eio_main.run @@ fun _env -> KEC.effective_model_labels_for_turn meta

let make_meta ?(last_model_used = "glm-5.1") ?(models = []) () =
  let base =
    match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String "keeper-llama-only-test");
          ("agent_name", `String "keeper-llama-only-test");
          ("trace_id", `String "trace-keeper-llama-only");
          ("cascade_name", `String Masc_mcp.(Keeper_config.default_cascade_name ()));
          ("last_model_used", `String last_model_used);
          ("sandbox_profile", `String "local");
          ("network_mode", `String "none");
        ])
    with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
  in
  { base with models }

(* Behavioral: stale model from a different provider is excluded from result.
   MASC does not assert specific vendor labels — only cascade behavior.
   The stale pin must have no effect: result equals the no-pin baseline. *)
let test_stale_last_model_is_not_reused_outside_current_cascade () =
  let baseline = labels_for_turn (make_meta ~last_model_used:"" ()) in
  check bool "baseline is non-empty" true (baseline <> []);
  let labels = labels_for_turn (make_meta ~last_model_used:"glm:glm-5.1" ()) in
  check (list string) "stale pin has no effect on cascade labels" baseline labels

(* Behavioral: when last_model_used matches a configured cascade model,
   it stays first in the returned labels. *)
let test_matching_last_model_is_preserved_when_still_in_cascade () =
  let baseline = labels_for_turn (make_meta ~last_model_used:"" ()) in
  match baseline with
  | [] -> fail "cascade resolved to empty labels"
  | first :: _ ->
    let labels = labels_for_turn (make_meta ~last_model_used:first ()) in
    match labels with
    | [] -> fail "matching allowed model resolved to empty labels"
    | actual_first :: _ ->
      check string "matching model stays first" first actual_first

let test_legacy_explicit_models_do_not_override_cascade_resolution () =
  let explicit =
    [ "ollama:qwen3.5:35b-a3b-nvfp4"; "glm-coding:glm-5.1" ]
  in
  let baseline = labels_for_turn (make_meta ~last_model_used:"" ()) in
  let labels =
    labels_for_turn (make_meta ~last_model_used:"" ~models:explicit ())
  in
  check (list string) "legacy explicit models do not override cascade" baseline labels

let test_meta_of_json_rejects_legacy_models () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String "keeper-llama-only-test");
          ("agent_name", `String "keeper-llama-only-test");
          ("trace_id", `String "trace-keeper-llama-models-drop");
          ("models", `List [ `String "glm:glm-5.1" ]);
          ("sandbox_profile", `String "local");
          ("network_mode", `String "none");
        ])
  with
  | Ok _ -> fail "meta_of_json should reject legacy models"
  | Error err ->
    check bool "legacy models rejected" true
      (contains_substring err "models")

let () =
  run "keeper_llama_only"
    [
      ( "effective_model_labels_for_turn",
        [
          test_case "drops stale glm pin outside current cascade" `Quick
            test_stale_last_model_is_not_reused_outside_current_cascade;
          test_case "keeps llama pin when still allowed" `Quick
            test_matching_last_model_is_preserved_when_still_in_cascade;
          test_case "ignores legacy explicit models for runtime labels" `Quick
            test_legacy_explicit_models_do_not_override_cascade_resolution;
          test_case "rejects legacy models while parsing keeper meta" `Quick
            test_meta_of_json_rejects_legacy_models;
        ] );
    ]
