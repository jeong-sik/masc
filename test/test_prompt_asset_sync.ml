(** Tests for [Prompt_defaults.sync_prompt_assets] (#20929) — converging the
    runtime prompt markdown dir onto binary-embedded assets. *)

open Alcotest
module Prompt_defaults = Masc.Prompt_defaults

let manifest_rel = "prompts/managed-assets.json"

let manifest paths =
  Yojson.Safe.to_string
    (`Assoc
       [ "schema", `String "masc.prompt-managed-assets.v1"
       ; "paths", `List (List.map (fun path -> `String path) paths)
       ])
;;

let embedded =
  [
    ( "prompts/keeper.example.md"
    , "---\ndescription: example\n---\nbody v2\n" )
  ; ( "prompts/behavior/contract.md"
    , "---\ndescription: contract\n---\nrules\n" )
  ; ( manifest_rel
    , manifest
        [ "keeper.example.md"; "behavior/contract.md"; "keeper.retired.md" ] )
  ; "runtime.toml", "[runtime]\n"
  ]

let read_embedded rel = List.assoc_opt rel embedded
let embedded_files = List.map fst embedded

let with_temp_prompts_dir f =
  let dir = Filename.temp_dir "prompt-asset-sync" "test" in
  Fun.protect
    ~finally:(fun () ->
      (* best-effort cleanup; leftover temp dirs are harmless *)
      try
        let rec rm path =
          if Sys.is_directory path then begin
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            Unix.rmdir path
          end
          else Sys.remove path
        in
        rm dir
      with Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f dir)

let read_file path = In_channel.with_open_text path In_channel.input_all

let sync ~prompts_dir =
  Prompt_defaults.sync_prompt_assets ~read:read_embedded ~files:embedded_files
    ~prompts_dir ()

let test_copies_missing_and_scopes_to_prompts () =
  with_temp_prompts_dir (fun dir ->
      let result = sync ~prompts_dir:dir in
      check (list string) "copied"
        [ "prompts/behavior/contract.md"; "prompts/keeper.example.md" ]
        (List.sort compare result.Prompt_defaults.copied);
      check (list string) "overwritten" [] result.Prompt_defaults.overwritten;
      check (list string) "removed" [] result.Prompt_defaults.removed;
      check int "failed" 0 (List.length result.Prompt_defaults.failed);
      check string "subdir content" "---\ndescription: contract\n---\nrules\n"
        (read_file (Filename.concat dir "behavior/contract.md"));
      check bool "non-prompts asset not written" false
        (Sys.file_exists (Filename.concat dir "runtime.toml")))

let test_second_run_is_noop () =
  with_temp_prompts_dir (fun dir ->
      let (_ : Prompt_defaults.sync_result) = sync ~prompts_dir:dir in
      let again = sync ~prompts_dir:dir in
      check (list string) "copied" [] again.Prompt_defaults.copied;
      check (list string) "overwritten" [] again.Prompt_defaults.overwritten)

let test_overwrites_stale_copy () =
  with_temp_prompts_dir (fun dir ->
      let (_ : Prompt_defaults.sync_result) = sync ~prompts_dir:dir in
      let stale = Filename.concat dir "keeper.example.md" in
      Out_channel.with_open_text stale (fun oc ->
          Out_channel.output_string oc "body v1 (stale)\n");
      let result = sync ~prompts_dir:dir in
      check (list string) "overwritten" [ "prompts/keeper.example.md" ]
        result.Prompt_defaults.overwritten;
      check (list string) "copied" [] result.Prompt_defaults.copied;
      check string "converged content"
        "---\ndescription: example\n---\nbody v2\n" (read_file stale))

let test_runtime_only_files_survive () =
  with_temp_prompts_dir (fun dir ->
      let extra = Filename.concat dir "operator.custom.md" in
      Out_channel.with_open_text extra (fun oc ->
          Out_channel.output_string oc "local-only\n");
      let (_ : Prompt_defaults.sync_result) = sync ~prompts_dir:dir in
      check bool "runtime-only file kept" true (Sys.file_exists extra);
      check string "runtime-only content kept" "local-only\n" (read_file extra))

let test_retired_managed_file_is_removed () =
  with_temp_prompts_dir (fun dir ->
      let retired = Filename.concat dir "keeper.retired.md" in
      Out_channel.with_open_text retired (fun oc ->
          Out_channel.output_string oc "retired distribution copy\n");
      let result = sync ~prompts_dir:dir in
      check (list string) "removed" [ "prompts/keeper.retired.md" ]
        result.Prompt_defaults.removed;
      check bool "retired asset absent" false (Sys.file_exists retired))

let test_invalid_manifest_preserves_managed_file () =
  with_temp_prompts_dir (fun dir ->
      let retired = Filename.concat dir "keeper.retired.md" in
      Out_channel.with_open_text retired (fun oc ->
          Out_channel.output_string oc "must survive invalid manifest\n");
      let read = function
        | rel when String.equal rel manifest_rel -> Some "{not-json"
        | rel -> read_embedded rel
      in
      let result =
        Prompt_defaults.sync_prompt_assets ~read ~files:embedded_files
          ~prompts_dir:dir ()
      in
      check (list string) "removed" [] result.Prompt_defaults.removed;
      check bool "retired asset preserved" true (Sys.file_exists retired);
      check bool "manifest failure visible" true
        (List.exists
           (fun (rel, _) -> String.equal rel manifest_rel)
           result.Prompt_defaults.failed))

let test_incomplete_manifest_preserves_managed_file () =
  with_temp_prompts_dir (fun dir ->
      let retired = Filename.concat dir "keeper.retired.md" in
      Out_channel.with_open_text retired (fun oc ->
          Out_channel.output_string oc "must survive incomplete manifest\n");
      let read = function
        | rel when String.equal rel manifest_rel ->
          Some (manifest [ "keeper.retired.md" ])
        | rel -> read_embedded rel
      in
      let result =
        Prompt_defaults.sync_prompt_assets ~read ~files:embedded_files
          ~prompts_dir:dir ()
      in
      check (list string) "removed" [] result.Prompt_defaults.removed;
      check bool "retired asset preserved" true (Sys.file_exists retired);
      check bool "manifest coverage failure visible" true
        (List.exists
           (fun (rel, _) -> String.equal rel manifest_rel)
           result.Prompt_defaults.failed))

let test_unreadable_embedded_entry_is_failed () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Prompt_defaults.sync_prompt_assets
          ~read:(function
            | rel when String.equal rel manifest_rel ->
              Some (manifest [ "ghost.md" ])
            | _ -> None)
          ~files:[ "prompts/ghost.md"; manifest_rel ]
          ~prompts_dir:dir ()
      in
      check int "failed count" 1 (List.length result.Prompt_defaults.failed);
      match result.Prompt_defaults.failed with
      | [ (rel, _) ] -> check string "failed entry" "prompts/ghost.md" rel
      | _ -> fail "expected exactly one failure")

let test_binary_manifest_covers_current_assets () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Prompt_defaults.sync_prompt_assets
          ~read:Embedded_config.read
          ~files:Embedded_config.file_list
          ~prompts_dir:dir
          ()
      in
      check (list (pair string string)) "all embedded prompt assets managed" []
        result.Prompt_defaults.failed)

let () =
  run "prompt_asset_sync"
    [
      ( "sync",
        [
          test_case "copies missing, scopes to prompts/" `Quick
            test_copies_missing_and_scopes_to_prompts;
          test_case "second run is a no-op" `Quick test_second_run_is_noop;
          test_case "overwrites stale runtime copy" `Quick
            test_overwrites_stale_copy;
          test_case "runtime-only files are never deleted" `Quick
            test_runtime_only_files_survive;
          test_case "retired managed file is removed" `Quick
            test_retired_managed_file_is_removed;
          test_case "invalid manifest preserves managed files" `Quick
            test_invalid_manifest_preserves_managed_file;
          test_case "incomplete manifest preserves managed files" `Quick
            test_incomplete_manifest_preserves_managed_file;
          test_case "unreadable embedded entry recorded as failure" `Quick
            test_unreadable_embedded_entry_is_failed;
          test_case "binary manifest covers current prompt assets" `Quick
            test_binary_manifest_covers_current_assets;
        ] );
    ]
