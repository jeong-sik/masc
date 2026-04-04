open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module KT = Masc_mcp.Keeper_types

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

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

let make_meta ?(last_model_used = "glm-5.1") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String "keeper-llama-only-test");
          ("agent_name", `String "keeper-llama-only-test");
          ("trace_id", `String "trace-keeper-llama-only");
          ("cascade_name", `String "keeper_unified");
          ("last_model_used", `String last_model_used);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let test_stale_last_model_is_not_reused_outside_current_cascade () =
  let labels = labels_for_turn (make_meta ()) in
  check (list string) "llama-only cascade excludes stale glm pin"
    [ Printf.sprintf "llama:%s" Masc_mcp.Env_config_runtime.Llama.default_model ] labels

let test_matching_last_model_is_preserved_when_still_in_cascade () =
  let labels = labels_for_turn (make_meta ~last_model_used:(Printf.sprintf "llama:%s" Masc_mcp.Env_config_runtime.Llama.default_model) ()) in
  check (list string) "llama label stays first when still allowed"
    [ Printf.sprintf "llama:%s" Masc_mcp.Env_config_runtime.Llama.default_model ] labels

let () =
  run "keeper_llama_only"
    [
      ( "effective_model_labels_for_turn",
        [
          test_case "drops stale glm pin outside current cascade" `Quick
            test_stale_last_model_is_not_reused_outside_current_cascade;
          test_case "keeps llama pin when still allowed" `Quick
            test_matching_last_model_is_preserved_when_still_in_cascade;
        ] );
    ]
