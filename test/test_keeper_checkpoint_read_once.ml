(** What the checkpoint store reads from the canonical file, and when it
    answers without reading it. The locked read takes the whole file into one
    allocation of its size and keeps the answers of the read it replaced: the
    same bytes and digest, and the same refusals for a missing, symlinked,
    unreadable or truncated canonical. *)

open Alcotest
open Masc
module Store = Keeper_checkpoint_store
module Observation = Store.Read_observation

let history_retained () =
  Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained

let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages =
    [ Agent_core.Types.
        { origin = Llm_provider.Types.Conversation;  role = User; content = [ Text "hello" ]; name = None; tool_call_id = None
        ; metadata = [] }
    ; Agent_core.Types.
        { origin = Llm_provider.Types.Conversation;  role = Assistant; content = [ Text marker ]; name = None
        ; tool_call_id = None; metadata = [] }
    ]
  in
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version
    ; session_id
    ; agent_name = "agent_core-test-runtime"
    ; model = "test-model"
    ; system_prompt = None
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count
    ; created_at = 1000.0
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
    ; working_context = None
    }

(* Larger than one [Unix.read], which moves at most 64 KB a call. *)
let several_reads_marker = String.make 300_000 'm'

let with_session f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let root = Filename.temp_file "keeper-checkpoint-read-once" "" in
    Unix.unlink root;
    Unix.mkdir root 0o700;
    let session_dir = Filename.concat root "session" in
    Unix.mkdir session_dir 0o700;
    let rec remove path =
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Unix.chmod path 0o700;
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Unix.unlink path
    in
    Fun.protect ~finally:(fun () -> remove root) (fun () -> f session_dir))

let canonical_path session_dir = Store.agent_core_checkpoint_path ~session_dir ~session_id:"session"
let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path bytes = Out_channel.with_open_bin path (fun ch -> output_string ch bytes)
let replace_file path bytes =
  match Fs_compat.save_file_atomic path bytes with Ok () -> () | Error detail -> fail detail
(* A reference names the head's content digest. *)
let content_digest_of_head bytes =
  match Agent_core.Checkpoint_objects.head_of_string bytes with
  | Ok head -> (Agent_core.Checkpoint_objects.head_content_digest head :> string)
  | Error error -> fail (Agent_core.Checkpoint_objects.load_error_to_string error)

let save_plain ~session_dir checkpoint =
  match Store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~history_retained:(history_retained ()) ~session_dir checkpoint with
  | Ok _ -> ()
  | Error error -> fail ("save failed: " ^ error)

let load_snapshot ~session_dir label =
  match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:"session" with
  | Ok snapshot -> snapshot
  | Error error -> failf "%s: %s" label (Store.checkpoint_ref_load_error_to_string error)

let refused_as label expected session_dir =
  match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:"session", expected with
  | Error Store.Ref_not_found, `Absent
  | Error (Store.Ref_read_failed (Store.Io_error _)), `Io_error
  | Error (Store.Ref_read_failed (Store.Read_failed { cause = Store.Os_error Unix.EACCES; _ })),
    `Read_failed_eacces
  | Error (Store.Ref_read_failed (Store.Parse_error _)), `Parse_error -> ()
  | Error error, _ -> failf "%s: refused as %s" label (Store.checkpoint_ref_load_error_to_string error)
  | Ok _, _ -> failf "%s: the canonical was accepted" label

let test_the_reference_is_the_content_digest_of_the_head () = with_session (fun session_dir ->
  let checkpoint = make_checkpoint ~session_id:"session" ~turn_count:4 ~marker:several_reads_marker in
  save_plain ~session_dir checkpoint;
  let on_disk = read_file (canonical_path session_dir) in
  let snapshot = load_snapshot ~session_dir "the canonical did not load" in
  check string "the reference is the head's content digest" (content_digest_of_head on_disk)
    (Store.exact_snapshot_reference snapshot).sha256;
  (match Agent_core.Checkpoint_objects.content_digest (Agent_core.Checkpoint_objects.create_memo ()) checkpoint with
   | Ok digest ->
     check string "the saved value has the same content digest" (digest :> string)
       (Store.exact_snapshot_reference snapshot).sha256
   | Error error -> fail (Agent_core.Error.to_string error));
  check int "the reference carries the file's turn" 4 (Store.exact_snapshot_reference snapshot).turn_count)

let test_a_missing_canonical_is_absent () = with_session (fun session_dir ->
  refused_as "a missing canonical" `Absent session_dir)

let test_a_symlinked_canonical_is_refused () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"linked");
  let path = canonical_path session_dir in
  let target = Filename.concat (Filename.dirname session_dir) "outside.json" in
  write_file target (read_file path);
  Sys.remove path;
  Unix.symlink target path;
  refused_as "a symlinked canonical" `Io_error session_dir)

let test_a_directory_at_the_canonical_path_is_refused () = with_session (fun session_dir ->
  Unix.mkdir (canonical_path session_dir) 0o700;
  refused_as "a directory canonical" `Io_error session_dir)

(* An unreadable-but-present canonical fails the read itself: open(2)
   raises EACCES, which load_canonical_bytes_strict reports as
   Read_failed { Os_error EACCES }. Io_error is only for a path that is
   not a regular file, where the path, not the read, is at fault. *)
let test_an_unreadable_canonical_is_refused () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"unreadable");
  let path = canonical_path session_dir in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o600) (fun () ->
    refused_as "an unreadable canonical" `Read_failed_eacces session_dir))

let test_a_truncated_canonical_is_a_parse_error () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:several_reads_marker);
  let path = canonical_path session_dir in
  let bytes = read_file path in
  write_file path (String.sub bytes 0 (String.length bytes / 2));
  refused_as "a truncated canonical" `Parse_error session_dir;
  write_file path "";
  refused_as "an empty canonical" `Parse_error session_dir)

(* The summary key resolves only the session root. A canonical that is a link
   to another session's canonical is not that session's file, so it is not
   answered from the summary of the file it points to: the reader goes to the
   file and refuses the link. *)
let test_a_linked_canonical_is_not_answered_from_its_target () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"target");
  (match Store.canonical_message_count ~session_dir ~session_id:"session" with
   | Ok (Some 2) -> ()
   | Ok _ | Error _ -> fail "the target's own count was not two messages");
  let other_dir = Filename.concat (Filename.dirname session_dir) "other" in
  Unix.mkdir other_dir 0o700;
  Unix.symlink (canonical_path session_dir) (canonical_path other_dir);
  match Store.canonical_message_count ~session_dir:other_dir ~session_id:"session" with
  | Error (Store.Io_error _) -> ()
  | Error error -> failf "the link was refused as %s" (Store.checkpoint_load_error_to_string error)
  | Ok _ -> fail "the link was answered from its target's summary")

let keeper = "read-once-keeper"

let save_for_keeper ~session_dir checkpoint =
  match
    Store.save_agent_core_for_keeper ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~keeper_name:keeper ~history_retained:(history_retained ())
      ~session_dir checkpoint
  with
  | Ok _ -> ()
  | Error error -> fail ("keeper save failed: " ^ error)

let load_value ~session_dir label =
  match Store.load_agent_core ~session_dir ~session_id:"session" with
  | Ok checkpoint -> checkpoint
  | Error error -> failf "%s: %s" label (Store.checkpoint_load_error_to_string error)

(* The exact snapshot of a file a Keeper wrote hands out the value the Keeper's
   lineage holds for it, the one [load_agent_core] answers with, and reads only
   the bytes it carries. A decode would make new message records. *)
let test_a_keeper_snapshot_uses_the_kept_decode () = with_session (fun session_dir ->
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:several_reads_marker);
  let kept = load_value ~session_dir "the kept value did not load" in
  let snapshot = load_snapshot ~session_dir "the snapshot did not load" in
  let on_disk = read_file (canonical_path session_dir) in
  check bool "the snapshot's messages are the kept value's" true
    (Store.exact_snapshot_messages snapshot == kept.messages);
  check string "the reference is the head's content digest" (content_digest_of_head on_disk)
    (Store.exact_snapshot_reference snapshot).sha256;
  check int "the reference carries the kept turn" 2 (Store.exact_snapshot_reference snapshot).turn_count)

(* A file replaced behind the Keeper's lineage is a new identity: the snapshot
   decodes the bytes it read. *)
let test_a_snapshot_behind_a_replaced_file_decodes_it () = with_session (fun session_dir ->
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:"kept");
  let kept = load_value ~session_dir "the kept value did not load" in
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:3 ~marker:"replaced");
  let snapshot = load_snapshot ~session_dir "the snapshot did not load" in
  check bool "the snapshot did not hand out the kept messages" true
    (Store.exact_snapshot_messages snapshot != kept.messages);
  check int "the snapshot is the replacing file" 3 (Store.exact_snapshot_reference snapshot).turn_count;
  match List.rev (Store.exact_snapshot_messages snapshot) with
  | { Agent_core.Types.content = [ Agent_core.Types.Text text ]; _ } :: _ ->
    check string "the last message is the replacing file's" "replaced" text
  | _ -> fail "the replacing file's last message was not one text block")

(* A snapshot taken since a known source: unchanged bytes are found by digest
   alone, and changed bytes the Keeper's lineage holds are handed out as its
   value rather than decoded again, both through the locked callback and
   through the read-then-decode pair. *)
let test_a_changed_source_since_a_snapshot_uses_the_kept_decode () = with_session (fun session_dir ->
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"known");
  let known = Store.exact_snapshot_source (load_snapshot ~session_dir "the known snapshot did not load") in
  (match Store.with_agent_core_exact_snapshot_since ~session_dir ~known Fun.id with
   | Ok Store.Unchanged_source -> ()
   | Ok (Store.Changed_source _) -> fail "the known bytes were reported as changed"
   | Error error -> failf "the unchanged check failed: %s" (Store.checkpoint_ref_load_error_to_string error));
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:several_reads_marker);
  let kept = load_value ~session_dir "the kept value did not load" in
  let on_disk = read_file (canonical_path session_dir) in
  let check_changed label snapshot =
    check bool (label ^ ": the messages are the kept value's") true
      (Store.exact_snapshot_messages snapshot == kept.messages);
    check string (label ^ ": the reference is the head's content digest") (content_digest_of_head on_disk)
      (Store.exact_snapshot_reference snapshot).sha256;
    check int (label ^ ": the reference carries the kept turn") 2
      (Store.exact_snapshot_reference snapshot).turn_count
  in
  (match Store.with_agent_core_exact_snapshot_since ~session_dir ~known Fun.id with
   | Ok (Store.Changed_source snapshot) -> check_changed "locked" snapshot
   | Ok Store.Unchanged_source -> fail "the changed bytes were reported as unchanged"
   | Error error -> failf "the changed snapshot failed: %s" (Store.checkpoint_ref_load_error_to_string error));
  match Store.read_agent_core_exact_bytes_since ~session_dir ~known with
  | Ok (Store.Changed_bytes changed) ->
    (match Store.decode_changed_bytes changed with
     | Ok snapshot -> check_changed "read then decode" snapshot
     | Error error -> failf "the changed decode failed: %s" (Store.checkpoint_ref_load_error_to_string error))
  | Ok Store.Unchanged_bytes -> fail "the changed bytes were read as unchanged"
  | Error error -> failf "the changed read failed: %s" (Store.checkpoint_ref_load_error_to_string error))

(* A save lands between the unlocked read and its decode. The decode answers
   for the bytes it was handed, matched by the identity they were read under:
   the lineage now holds the newer file's value, so the bytes are decoded. *)
let test_a_decode_after_a_later_save_answers_for_the_bytes_read () = with_session (fun session_dir ->
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"known");
  let known = Store.exact_snapshot_source (load_snapshot ~session_dir "the known snapshot did not load") in
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:"read");
  let read_bytes = read_file (canonical_path session_dir) in
  match Store.read_agent_core_exact_bytes_since ~session_dir ~known with
  | Ok Store.Unchanged_bytes -> fail "the changed bytes were read as unchanged"
  | Error error -> failf "the changed read failed: %s" (Store.checkpoint_ref_load_error_to_string error)
  | Ok (Store.Changed_bytes changed) ->
    save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:3 ~marker:"later");
    let later = load_value ~session_dir "the later value did not load" in
    match Store.decode_changed_bytes changed with
    | Error error -> failf "the changed decode failed: %s" (Store.checkpoint_ref_load_error_to_string error)
    | Ok snapshot ->
      check int "the snapshot is the turn that was read" 2
        (Store.exact_snapshot_reference snapshot).turn_count;
      check string "the reference is the content digest of the head read" (content_digest_of_head read_bytes)
        (Store.exact_snapshot_reference snapshot).sha256;
      check bool "the messages are not the later save's value" true
        (Store.exact_snapshot_messages snapshot != later.messages))

(* The file is unreadable inside [f], so an answer proves the store did not
   read it. *)
let while_unreadable path f =
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o600) f

let test_a_cold_count_keeps_only_the_same_head () = with_session (fun session_dir ->
  let checkpoint = make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"cold" in
  save_plain ~session_dir checkpoint;
  let cold_dir = Filename.concat (Filename.dirname session_dir) "cold" in
  Unix.mkdir cold_dir 0o700;
  let path = canonical_path cold_dir in
  let install bytes =
    let staged = Filename.concat cold_dir "next.json" in
    write_file staged bytes;
    Unix.rename staged path in
  install (read_file (canonical_path session_dir));
  let count label expected =
    match Store.canonical_message_count ~session_dir:cold_dir ~session_id:"session" with
    | Ok actual -> check (option int) label expected actual
    | Error error -> failf "%s: %s" label (Store.checkpoint_load_error_to_string error) in
  count "a cold head supplies its count" (Some 2);
  while_unreadable path (fun () -> count "the same head is not read again" (Some 2));
  (* No object was copied. Counting a head must not turn that observation
     into permission to load a checkpoint whose objects are absent. *)
  (match Store.load_agent_core ~session_dir:cold_dir ~session_id:"session" with
   | Error (Store.Objects_invalid _) -> ()
   | Error error -> failf "full load failed with the wrong class: %s"
       (Store.checkpoint_load_error_to_string error)
   | Ok _ -> fail "a head-only count was treated as a validated checkpoint");
  save_plain ~session_dir
    { checkpoint with turn_count = 2; messages = checkpoint.messages @ checkpoint.messages };
  install (read_file (canonical_path session_dir));
  count "a replaced canonical supplies the new count" (Some 4);
  while_unreadable path (fun () -> count "the replacement also supplies a summary" (Some 4));
  install "{";
  (match Store.canonical_message_count ~session_dir:cold_dir ~session_id:"session" with
   | Error (Store.Parse_error _) -> ()
   | Error error -> failf "malformed head failed with the wrong class: %s"
       (Store.checkpoint_load_error_to_string error)
   | Ok _ -> fail "a malformed replacement reused the old count");
  Sys.remove path;
  count "a removed canonical is absent" None)

(* A configured root re-pointed while the process runs. The save that follows
   resolves the root afresh and lands under the new target; the lookups and
   the forget through the configured spelling follow that save rather than
   the target they resolved first. *)
let test_a_repointed_root_moves_lookups_with_the_save () = with_session (fun session_dir ->
  let scratch = Filename.dirname session_dir in
  let first_root = Filename.concat scratch "first-root" in
  let second_root = Filename.concat scratch "second-root" in
  List.iter (fun root -> Unix.mkdir root 0o700; Unix.mkdir (Filename.concat root "trace") 0o700)
    [ first_root; second_root ];
  let linked_root = Filename.concat scratch "linked-root" in
  Unix.symlink first_root linked_root;
  let trace_dir = Filename.concat linked_root "trace" in
  save_for_keeper ~session_dir:trace_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"first");
  check int "the first target answers" 1 (load_value ~session_dir:trace_dir "the first load failed").turn_count;
  Unix.unlink linked_root;
  Unix.symlink second_root linked_root;
  let second = make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:"second" in
  save_for_keeper ~session_dir:trace_dir
    { second with messages = second.messages @ second.messages };
  check bool "the second save landed under the new target" true
    (Sys.file_exists (canonical_path (Filename.concat second_root "trace")));
  while_unreadable (canonical_path trace_dir) (fun () ->
    (match Store.canonical_message_count ~session_dir:trace_dir ~session_id:"session" with
     | Ok (Some 4) -> ()
     | Ok _ -> fail "the count did not describe the second save"
     | Error _ -> fail "the count read the file: its lookup did not follow the save");
    check int "the load answers from the second save's value" 2
      (load_value ~session_dir:trace_dir "the load read the file").turn_count;
    Store.forget_written_lineages ~session_root:linked_root ~keeper_name:keeper;
    match Store.load_agent_core ~session_dir:trace_dir ~session_id:"session" with
    | Error _ -> ()
    | Ok _ -> fail "the forget left the value kept under the new target"))

let observed_load session_dir =
  match Observation.load ~session_dir ~session_id:"session" with
  | Ok observed -> observed
  | Error error -> fail (Store.checkpoint_load_error_to_string error)

let expect_unchanged label witness =
  match Observation.revalidate witness with
  | Observation.Unchanged -> ()
  | Refreshed _ -> fail (label ^ ": unexpectedly refreshed")
  | Changed -> fail (label ^ ": changed")
  | Unavailable error -> failf "%s: %s" label (Store.checkpoint_load_error_to_string error)

let expect_not_reusable label witness =
  match Observation.revalidate witness with
  | Observation.Changed | Unavailable _ -> ()
  | Unchanged | Refreshed _ -> fail (label ^ ": reused a changed or unreadable source")

let bundle_path session_dir =
  match Agent_core.Checkpoint_objects.head_of_string (read_file (canonical_path session_dir)) with
  | Error error -> fail (Agent_core.Checkpoint_objects.load_error_to_string error)
  | Ok head ->
    match head.history.turns with
    | turn :: _ -> Keeper_checkpoint_object_store.path ~session_dir turn.bundle, turn.bundle
    | [] -> fail "fixture has no closed turn"

let test_observation_reads_and_revalidates_without_retaining_a_lineage () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:several_reads_marker);
  let loaded, witness = observed_load session_dir in
  check int "observed the complete checkpoint" 2 (List.length loaded.messages);
  expect_unchanged "unchanged source" witness;
  let path, _digest = bundle_path session_dir in
  let bytes = read_file path in
  (match Fs_compat.save_file_atomic path bytes with Ok () -> () | Error detail -> fail detail);
  expect_not_reusable "identical bytes under a replacement identity" witness;
  let again, refreshed = observed_load session_dir in
  check bool "a full reread preserves the messages" true (loaded.messages = again.messages);
  expect_unchanged "replacement was verified by a fresh read" refreshed)

let test_observation_refreshes_only_a_fresh_header_over_the_same_graph () = with_session (fun session_dir ->
  let module Objects = Agent_core.Checkpoint_objects in
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"body");
  let initial_reads = ref [] in
  let _, witness = match Observation.For_testing.load_after_object_read
      ~after_object_read:(fun digest -> initial_reads := digest :: !initial_reads)
      ~session_dir ~session_id:"session" with
    | Ok observed -> observed | Error error -> fail (Store.checkpoint_load_error_to_string error) in
  let _, bundle = bundle_path session_dir in
  check bool "the cold witness verified actual history" true (List.mem bundle !initial_reads);
  let path = canonical_path session_dir in
  let original_bytes = read_file path in
  let original_head = Objects.head_of_string original_bytes |> Result.get_ok in
  let refresh witness =
    let reads = ref [] in
    let observed = Observation.For_testing.revalidate_after_object_read
        ~after_object_read:(fun digest -> reads := digest :: !reads) witness in
    check bool "refresh reads header bodies only, in their original order" true
      (List.rev !reads = [original_head.header_objects.system_prompt; original_head.header_objects.tools]);
    let refreshed = match observed with
      | Observation.Refreshed witness -> witness
      | Unavailable error -> fail (Store.checkpoint_load_error_to_string error)
      | Unchanged | Changed -> fail "a verified replacement did not refresh the witness" in
    reads := [];
    (match Observation.For_testing.revalidate_after_object_read
        ~after_object_read:(fun digest -> reads := digest :: !reads) refreshed with
     | Observation.Unchanged -> ()
     | Refreshed _ | Changed | Unavailable _ -> fail "the returned witness did not bind the new head");
    check int "the next unchanged check reads no object body" 0 (List.length !reads);
    refreshed
  in
  replace_file path original_bytes;
  let witness = refresh witness in
  let snapshot = load_snapshot ~session_dir "current header" in
  let checkpoint = Store.exact_snapshot_checkpoint snapshot in
  let context = Agent_core.Context.copy checkpoint.context in
  Agent_core.Context.set context "execution_scope" (`String "restored-operation");
  (match Store.save_agent_core_if_source ~session_dir
      ~expected_source_ref:(Store.exact_snapshot_reference snapshot)
      ~boundary:Objects.Turn_continues {checkpoint with context}
      |> Store.require_confirmed_installation with
   | Ok _ -> ()
   | Error _ -> fail "the actual context-only CAS did not install");
  let changed_bytes = read_file path in
  let changed_head = Objects.head_of_string changed_bytes |> Result.get_ok in
  check bool "the CAS really changes the header" false (String.equal original_bytes changed_bytes);
  check bool "the context-only CAS preserves the exact history" true
    (original_head.history = changed_head.history);
  check bool "and preserves header-object references" true
    (original_head.header_objects = changed_head.header_objects);
  ignore (refresh witness))

let test_observation_invalidates_every_named_object () =
  with_session (fun session_dir ->
    let module Objects = Agent_core.Checkpoint_objects in
    let memo = Objects.create_memo () in
    let objects_dir = Filename.concat session_dir "objects" in
    Unix.mkdir objects_dir 0o700;
    let install ?previous boundary checkpoint =
      let plan = match Objects.plan_save memo ?previous boundary checkpoint with
        | Ok plan -> plan | Error error -> fail (Agent_core.Error.to_string error) in
      List.iter (fun (digest, bytes) ->
        let path = Keeper_checkpoint_object_store.path ~session_dir digest in
        let directory = Filename.dirname path in
        if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
        write_file path bytes) plan.objects;
      write_file (canonical_path session_dir) plan.head_bytes;
      plan
    in
    let rec close index previous messages =
      let turn = make_checkpoint ~session_id:"session" ~turn_count:index
        ~marker:(string_of_int index) in
      let plan = install ?previous Objects.Turn_closes
        { turn with messages = messages @ turn.messages } in
      if index = (2 * Objects.turns_per_segment) + 1 then plan
      else close (index + 1) (Some plan.head) plan.decoded.messages
    in
    let closed = close 1 None [] in
    let continued = install ~previous:closed.head Objects.Turn_continues
      { closed.decoded with messages = closed.decoded.messages @
          (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"open").messages } in
    let head = continued.head in
    let segment = match head.history.segment with
      | Some segment -> segment.segment | None -> fail "fixture has no segment" in
    let load_segment digest =
      match Objects.segment_of_string ~digest
          (read_file (Keeper_checkpoint_object_store.path ~session_dir digest)) with
      | Ok segment -> segment | Error error -> fail (Objects.load_error_to_string error) in
    let previous_segment = match (load_segment segment).previous with
      | Some digest -> digest | None -> fail "fixture has no transitive segment" in
    let transitive_bundle = match (load_segment previous_segment).segment_turns with
      | turn :: _ -> turn.bundle | [] -> fail "fixture has no transitive bundle" in
    let direct_bundle = match head.history.turns with
      | turn :: _ -> turn.bundle | [] -> fail "fixture has no direct bundle" in
    let open_message = match head.history.open_messages with
      | digest :: _ -> digest | [] -> fail "fixture has no open message" in
    List.iter (fun replaced_head -> List.iter (fun (label, digest) ->
    let _checkpoint, witness = observed_load session_dir in
    if replaced_head then replace_file (canonical_path session_dir) (read_file (canonical_path session_dir));
    let path = Keeper_checkpoint_object_store.path ~session_dir digest in
    let bytes = read_file path in
    write_file path "corrupted object";
    expect_not_reusable label witness;
    (match Observation.load ~session_dir ~session_id:"session" with
     | Error (Store.Objects_invalid (Objects.Object_digest_mismatch _)) -> ()
     | Error error -> failf "%s: wrong error %s" label (Store.checkpoint_load_error_to_string error)
     | Ok _ -> fail (label ^ ": returned a witness for a corrupt object"));
    write_file path bytes)
    [ "system prompt", head.header_objects.system_prompt
    ; "tool schemas", head.header_objects.tools
    ; "direct segment", segment
    ; "transitive segment", previous_segment
    ; "transitive turn bundle", transitive_bundle
    ; "direct turn bundle", direct_bundle
    ; "open message", open_message ]) [false; true])

let test_observation_refuses_missing_linked_and_unreadable_objects () =
  List.iter (fun replaced_head -> List.iter (fun (label, mutate) -> with_session (fun session_dir ->
    save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"body");
    let _checkpoint, witness = observed_load session_dir in
    if replaced_head then replace_file (canonical_path session_dir) (read_file (canonical_path session_dir));
    let path, _digest = bundle_path session_dir in
    mutate session_dir path;
    expect_not_reusable label witness;
    match Observation.load ~session_dir ~session_id:"session" with
    | Error (Store.Objects_invalid _) -> ()
    | Error error -> failf "%s: wrong error %s" label (Store.checkpoint_load_error_to_string error)
    | Ok _ -> fail (label ^ ": returned an unavailable object's witness")))
    [ "missing", (fun _session_dir path -> Unix.unlink path)
    ; "truncated", (fun _session_dir path -> write_file path "")
    ; "symlink", (fun session_dir path ->
        let outside = Filename.concat (Filename.dirname session_dir) "outside-object" in
        write_file outside (read_file path); Unix.unlink path; Unix.symlink outside path)
    ; "permission changed", (fun _session_dir path -> Unix.chmod path 0o000) ]) [false; true]

let test_observation_refresh_keeps_fresh_head_and_object_race_checks () =
  List.iter (fun target -> with_session (fun session_dir ->
    save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"body");
    let _, witness = observed_load session_dir in
    let path = canonical_path session_dir in
    let bytes = read_file path in
    replace_file path bytes;
    let object_path, _ = bundle_path session_dir in
    let changed = ref false in
    let after_object_read _digest =
      if not !changed then (
        changed := true;
        match target with
        | `Head -> replace_file path bytes
        | `Body -> write_file object_path "changed during header validation"
        | `Cancel -> raise (Eio.Cancel.Cancelled Exit)) in
    (match Observation.For_testing.revalidate_after_object_read ~after_object_read witness with
     | Observation.Changed when target <> `Cancel -> ()
     | exception Eio.Cancel.Cancelled Exit when target = `Cancel -> ()
     | Unchanged | Refreshed _ | Changed | Unavailable _ ->
       fail "a refresh ignored a concurrent source change or cancellation");
    check bool "the race ran after an actual header-object read" true !changed))
    [`Head; `Body; `Cancel]

let test_observation_refuses_a_changed_or_truncated_head () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"first");
  let _checkpoint, witness = observed_load session_dir in
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:2 ~marker:"second");
  expect_not_reusable "new canonical" witness;
  let checkpoint, witness = observed_load session_dir in
  check int "new load names the new turn" 2 checkpoint.turn_count;
  write_file (canonical_path session_dir) "{";
  expect_not_reusable "truncated canonical" witness;
  (match Observation.load ~session_dir ~session_id:"session" with
   | Error (Store.Parse_error _) -> ()
   | Error error -> fail (Store.checkpoint_load_error_to_string error)
   | Ok _ -> fail "a truncated head produced a witness");
  Unix.unlink (canonical_path session_dir);
  match Observation.load ~session_dir ~session_id:"session" with
  | Error Store.Not_found -> ()
  | Error error -> fail (Store.checkpoint_load_error_to_string error)
  | Ok _ -> fail "an absent head produced a witness")

let test_observation_refresh_refuses_changed_session_and_malformed_header () =
  List.iter (fun (field, value, identity_change) -> with_session (fun session_dir ->
    save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"body");
    let _, witness = observed_load session_dir in
    let path = canonical_path session_dir in
    let json = match Yojson.Safe.from_string (read_file path) with
      | `Assoc fields -> `Assoc (List.map (function
          | "checkpoint", `Assoc header ->
            "checkpoint", `Assoc (List.map (fun (name, old) ->
              name, if String.equal name field then value else old) header)
          | pair -> pair) fields)
      | _ -> fail "fixture has no checkpoint head" in
    replace_file path (Yojson.Safe.to_string json);
    let reads = ref 0 in
    (match Observation.For_testing.revalidate_after_object_read
        ~after_object_read:(fun _digest -> incr reads) witness with
     | Observation.Changed when identity_change -> ()
     | Unavailable _ when not identity_change -> ()
     | Unchanged | Refreshed _ | Changed | Unavailable _ ->
       fail "a changed session or malformed header reused the old proof");
    check int "fresh parse or graph mismatch stops before header-object reads" 0 !reads))
    [ "session_id", `String "another-session", true
    ; "context", `List [], false
    ; "pending_input", `Assoc [], false
    ; "version", `Int (Agent_core.Checkpoint.checkpoint_version + 1), false
    ; "messages", `List [Agent_core.Checkpoint.message_to_json (Agent_core.Types.user_msg "hidden")], false
    ]

let test_observation_uses_the_snapshot_of_the_bytes_actually_read () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"read before change");
  let path, bundle = bundle_path session_dir in
  let mutated = ref false in
  let after_object_read (digest : Agent_core.Checkpoint_objects.digest) =
    if not !mutated && String.equal (digest :> string) (bundle :> string) then (
      mutated := true;
      write_file path "changed after the owned read") in
  match Observation.For_testing.load_after_object_read ~after_object_read
      ~session_dir ~session_id:"session" with
  | Error error -> fail (Store.checkpoint_load_error_to_string error)
  | Ok (checkpoint, witness) ->
    check bool "the race occurred at the bundle" true !mutated;
    check int "the value is the checkpoint actually read" 1 checkpoint.turn_count;
    expect_not_reusable "later bytes cannot inherit the earlier digest proof" witness)

let test_observation_reuses_only_an_eligible_written_lineage () = with_session (fun session_dir ->
  save_for_keeper ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"kept");
  let kept = load_value ~session_dir "kept value unavailable" in
  let loaded, witness = observed_load session_dir in
  check bool "observed reader keeps the existing fast path" true (loaded.messages == kept.messages);
  expect_unchanged "eligible lineage" witness;
  Store.forget_written_lineages ~session_root:(Filename.dirname session_dir) ~keeper_name:keeper;
  expect_not_reusable "evicted lineage no longer grants reuse" witness;
  let _checkpoint, cold = observed_load session_dir in
  expect_unchanged "cold reread verified every object" cold)

let () =
  run "keeper checkpoint read once"
    [ ( "locked read"
      , [ test_case "the reference is the content digest of the head" `Quick
            test_the_reference_is_the_content_digest_of_the_head
        ; test_case "a missing canonical is absent" `Quick test_a_missing_canonical_is_absent
        ; test_case "a symlinked canonical is refused" `Quick test_a_symlinked_canonical_is_refused
        ; test_case "a directory at the canonical path is refused" `Quick
            test_a_directory_at_the_canonical_path_is_refused
        ; test_case "an unreadable canonical is refused" `Quick test_an_unreadable_canonical_is_refused
        ; test_case "a truncated canonical is a parse error" `Quick
            test_a_truncated_canonical_is_a_parse_error
        ] )
    ; ( "summary key"
      , [ test_case "a linked canonical is not answered from its target" `Quick
            test_a_linked_canonical_is_not_answered_from_its_target
        ; test_case "a cold count keeps only the same head" `Quick
            test_a_cold_count_keeps_only_the_same_head
        ; test_case "a re-pointed root moves lookups with the save" `Quick
            test_a_repointed_root_moves_lookups_with_the_save
        ] )
    ; ( "read observation"
      , [ test_case "cold read and replacement revalidation" `Quick
            test_observation_reads_and_revalidates_without_retaining_a_lineage
        ; test_case "replacement and context-only CAS refresh only the header" `Quick
            test_observation_refreshes_only_a_fresh_header_over_the_same_graph
        ; test_case "every named object invalidates the witness" `Quick
            test_observation_invalidates_every_named_object
        ; test_case "missing, truncated, linked and unreadable objects refuse reuse" `Quick
            test_observation_refuses_missing_linked_and_unreadable_objects
        ; test_case "changed, truncated and absent heads refuse reuse" `Quick
            test_observation_refuses_a_changed_or_truncated_head
        ; test_case "changed session and malformed header cannot refresh" `Quick
            test_observation_refresh_refuses_changed_session_and_malformed_header
        ; test_case "witness belongs to the bytes read before a race" `Quick
            test_observation_uses_the_snapshot_of_the_bytes_actually_read
        ; test_case "header refresh preserves source-race and cancellation checks" `Quick
            test_observation_refresh_keeps_fresh_head_and_object_race_checks
        ; test_case "lineage witness expires with its existing eligibility" `Quick
            test_observation_reuses_only_an_eligible_written_lineage
        ] )
    ; ( "exact snapshot"
      , [ test_case "a keeper snapshot uses the kept decode" `Quick
            test_a_keeper_snapshot_uses_the_kept_decode
        ; test_case "a snapshot behind a replaced file decodes it" `Quick
            test_a_snapshot_behind_a_replaced_file_decodes_it
        ; test_case "a changed source since a snapshot uses the kept decode" `Quick
            test_a_changed_source_since_a_snapshot_uses_the_kept_decode
        ; test_case "a decode after a later save answers for the bytes read" `Quick
            test_a_decode_after_a_later_save_answers_for_the_bytes_read
        ] )
    ]
