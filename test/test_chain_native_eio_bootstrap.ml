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

let test_ensure_bootstrap_loads_sentinel_prompts () =
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
      Eio_main.run @@ fun _env ->
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      Lib.Chain_native_eio.ensure_bootstrap config;
      check bool "sentinel-board-patrol registered" true
        (Option.is_some (Lib.Prompt_registry.get ~id:"sentinel-board-patrol" ()));
      check bool "sentinel-task-hygiene registered" true
        (Option.is_some (Lib.Prompt_registry.get ~id:"sentinel-task-hygiene" ()));
      check bool "sentinel-keeper-health registered" true
        (Option.is_some (Lib.Prompt_registry.get ~id:"sentinel-keeper-health" ())))

let () =
  Alcotest.run "chain_native_eio_bootstrap"
    [
      ( "bootstrap",
        [
          test_case "loads sentinel prompts from repo data/prompts" `Quick
            test_ensure_bootstrap_loads_sentinel_prompts;
        ] );
    ]
