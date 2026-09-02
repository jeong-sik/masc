(** The binary's own prompt and tool assets sync into a runtime directory
    without a single failure.

    [Managed_asset_sync.sync] refuses the whole domain when the embedded
    manifest and the embedded asset set disagree -- the state of a binary
    built after a file was added to [config/prompts/] or [config/tools/]
    without a line in that domain's [managed-assets.json]. At boot that is
    one WARN line and every asset added since the last successful sync stays
    out of the runtime directory: on 2026-09-02 five tool-failure sentences
    and two previous-turn observations never reached a Keeper for that
    reason. This test runs the real sync over the real embedded set so the
    omission fails here, on the pull request, instead of at the next boot. *)

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
      ~read:Masc.Embedded_config.read
      ~files:Masc.Embedded_config.file_list
      ~dest_dir
      ()
  in
  check
    (list (pair string string))
    (label ^ ": every embedded asset is listed in its manifest")
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
        ] )
    ]
;;
