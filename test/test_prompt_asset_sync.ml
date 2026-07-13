(** Tests for [Prompt_defaults.sync_prompt_assets] (#20929) — converging the
    runtime prompt markdown dir onto binary-embedded assets. *)

open Alcotest
module Prompt_defaults = Masc.Prompt_defaults

let embedded =
  [
    ("prompts/keeper.example.md", "---\ndescription: example\n---\nbody v2\n");
    ("prompts/behavior/contract.md", "---\ndescription: contract\n---\nrules\n");
    ("runtime.toml", "[runtime]\n");
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

let test_unreadable_embedded_entry_is_failed () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Prompt_defaults.sync_prompt_assets
          ~read:(fun _ -> None)
          ~files:[ "prompts/ghost.md" ]
          ~prompts_dir:dir ()
      in
      check int "failed count" 1 (List.length result.Prompt_defaults.failed);
      match result.Prompt_defaults.failed with
      | [ (rel, _) ] -> check string "failed entry" "prompts/ghost.md" rel
      | _ -> fail "expected exactly one failure")

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
          test_case "unreadable embedded entry recorded as failure" `Quick
            test_unreadable_embedded_entry_is_failed;
        ] );
    ]
