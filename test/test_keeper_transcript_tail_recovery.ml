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

(* A canonical the build before the last [checkpoint_version] bump wrote, whose
   history ends in a tool call with no result. The next turn starts fresh and
   does not replay it, so there is nothing to close: every boot leaves the
   file as it is and counts no failure. *)
let test_a_superseded_checkpoint_has_nothing_to_recover () =
  with_workspace @@ fun config ->
  let name = "superseded-checkpoint" in
  let meta = make_meta name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let trace_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config) trace_id in
  Unix.mkdir session_dir 0o700;
  let open_call =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.Assistant
      [ Agent_core.Types.ToolUse { id = "call-open"; name = "read_file"; input = `Assoc [] } ]
  in
  let checkpoint : Agent_core.Checkpoint.t =
    { version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = trace_id
    ; agent_name = name
    ; model = "fixture-model"
    ; system_prompt = None
    ; messages =
        [ Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text "q" ]
        ; open_call
        ]
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let earlier =
    match Agent_core.Checkpoint.to_json checkpoint with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if String.equal key "version"
              then key, `Int (Agent_core.Checkpoint.checkpoint_version - 1)
              else key, value)
           fields)
    | _ -> fail "a checkpoint document is a JSON object"
  in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  let bytes = Yojson.Safe.to_string earlier in
  (match Fs_compat.save_file_atomic path bytes with
   | Ok () -> ()
   | Error detail -> failf "superseded fixture: %s" detail);
  (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id with
   | Error (Keeper_checkpoint_store.Superseded_version _) -> ()
   | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
   | Ok _ -> fail "the superseded fixture still loads");
  let boot label =
    let report = Recovery.recover_open_tails config in
    check int (label ^ ": no recovery failure") 0 report.Recovery.failed;
    check int (label ^ ": nothing closed") 0 report.Recovery.closed;
    match report.Recovery.outcomes with
    | [ (_, Recovery.Already_dispatchable) ] -> ()
    | [ (_, Recovery.Checkpoint_unavailable error) ] ->
      failf "%s: %s" label (Keeper_checkpoint_store.saved_history_ref_error_to_string error)
    | outcomes -> failf "%s: unexpected outcomes: %d" label (List.length outcomes)
  in
  boot "first boot";
  boot "next boot";
  check string "the superseded file is left in place" bytes
    (In_channel.with_open_bin path In_channel.input_all)
;;

let () =
  run
    "keeper_transcript_tail_recovery"
    [ ( "recover_open_tails"
      , [ test_case
            "a keeper without a canonical checkpoint has nothing to recover"
            `Quick
            test_a_keeper_without_a_canonical_checkpoint_has_nothing_to_recover
        ; test_case
            "a superseded checkpoint has nothing to recover"
            `Quick
            test_a_superseded_checkpoint_has_nothing_to_recover
        ] )
    ]
;;
