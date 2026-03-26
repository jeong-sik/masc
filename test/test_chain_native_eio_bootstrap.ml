module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_chain_bootstrap" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let test_ensure_bootstrap_omits_legacy_sentinel_prompts () =
  let dir = test_dir () in
  let previous_source_base = Sys.getenv_opt "MASC_CHAIN_SOURCE_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match previous_source_base with
       | Some value -> Unix.putenv "MASC_CHAIN_SOURCE_BASE_PATH" value
       | None -> Unix.putenv "MASC_CHAIN_SOURCE_BASE_PATH" "");
      cleanup_dir dir)
    (fun () ->
      let source_root =
        match Sys.getenv_opt "DUNE_SOURCEROOT" with
        | Some value -> value
        | None -> Sys.getcwd ()
      in
      Unix.putenv "MASC_CHAIN_SOURCE_BASE_PATH" source_root;
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      Lib.Chain_native_eio.ensure_bootstrap config;
      let has_legacy_sentinel_prompt =
        Lib.Prompt_registry.list_all ()
        |> List.exists (fun entry ->
               String.starts_with ~prefix:"sentinel-" entry.Lib.Prompt_registry.id)
      in
      check bool "legacy sentinel prompts removed" false
        has_legacy_sentinel_prompt)

let () =
  Alcotest.run "chain_native_eio_bootstrap"
    [
      ( "bootstrap",
        [
          test_case "omits legacy sentinel prompts from repo data/prompts" `Quick
            test_ensure_bootstrap_omits_legacy_sentinel_prompts;
        ] );
    ]
