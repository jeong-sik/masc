(** Boot-time transcript tail recovery over persisted keepers. *)

open Alcotest
open Masc

module Recovery = Keeper_transcript_tail_recovery

let make_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  let root = Filename.temp_file "transcript-tail-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      remove_tree root)
    (fun () -> f config)
;;

(* A persisted keeper whose trace has no canonical checkpoint -- an
   official-client lane, or a trace whose checkpoint a purge moved aside --
   has no open tool cycle to close. The session directory exists, as it does
   for such a keeper on a live workspace, and holds no checkpoint. *)
let test_a_keeper_without_a_canonical_checkpoint_has_nothing_to_recover () =
  with_workspace @@ fun config ->
  let name = "no-checkpoint" in
  let meta = make_meta name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let session_dir =
    Filename.concat
      (Keeper_fs.session_base_dir config)
      (Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
  in
  Unix.mkdir session_dir 0o700;
  let report = Recovery.recover_open_tails config in
  check int "one keeper examined" 1 report.Recovery.examined;
  check int "no recovery failure" 0 report.Recovery.failed;
  match report.Recovery.outcomes with
  | [ (reported, Recovery.Already_dispatchable) ] ->
    check string "the keeper is reported" name reported
  | [ (_, Recovery.Checkpoint_unavailable _) ] ->
    fail "a missing checkpoint is not a load failure"
  | outcomes -> failf "unexpected outcomes: %d" (List.length outcomes)
;;

let () =
  run
    "keeper_transcript_tail_recovery"
    [ ( "recover_open_tails"
      , [ test_case
            "a keeper without a canonical checkpoint has nothing to recover"
            `Quick
            test_a_keeper_without_a_canonical_checkpoint_has_nothing_to_recover
        ] )
    ]
;;
