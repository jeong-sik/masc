(** The binary's own prompt, tool, and MCP surface assets sync into a runtime
    directory without a single failure.

    The embedded tree is the managed set (#31283 removed the hand-written
    [managed-assets.json] that listed it a second time and drifted from it),
    so what is left to go wrong is the embedding itself: a crunch step that
    lost a domain, or an asset the sync cannot read or place. At boot that
    is one WARN line and a runtime directory missing what the binary
    carries: on 2026-09-02 five tool-failure sentences and two previous-turn
    observations never reached a Keeper for that reason. This test runs the
    real sync over the real embedded set so a broken embedding fails here,
    on the pull request, instead of at the next boot. *)

open Alcotest
module Sync = Masc.Managed_asset_sync

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_temp_dir f =
  let dir = Filename.temp_dir "managed-assets-from-binary" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let syncs_without_failure ~label ~domain () =
  with_temp_dir
  @@ fun dir ->
  let dest_dir = Filename.concat dir label in
  Unix.mkdir dest_dir 0o700;
  let result =
    Sync.sync
      ~domain
      ~read:Embedded_config.read
      ~files:Embedded_config.file_list
      ~dest_dir
      ()
  in
  check
    (list (pair string string))
    (label ^ ": every embedded asset syncs without failure")
    []
    result.Sync.failed;
  check bool (label ^ ": the runtime directory received the assets") true
    (List.length result.Sync.copied > 0)
;;

let () =
  run
    "managed assets sync from the binary"
    [ ( "sync"
      , [ test_case "prompts" `Quick
            (syncs_without_failure ~label:"prompts" ~domain:Sync.Prompts)
        ; test_case "tools" `Quick
            (syncs_without_failure ~label:"tools" ~domain:Sync.Tools)
        ; test_case "mcp" `Quick
            (syncs_without_failure ~label:"mcp" ~domain:Sync.Mcp)
        ] )
    ]
;;
