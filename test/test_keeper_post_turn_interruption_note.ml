(* RFC-0315 P2a — interruption note for no-[STATE] turns.

   A turn that produces no [STATE] snapshot is the same turn whose checkpoint
   replay suffix gets pruned and whose memory-bank writes are suppressed, so
   before this change it left the next turn with an empty continuity surface.
   These tests pin the repair: progress.md gains one forward-looking open
   question, existing forward content survives, and consecutive no-[STATE]
   turns do not stack duplicates. *)

open Alcotest
module P = Masc.Keeper_post_turn
module MP = Masc.Keeper_memory_policy

let tmp_progress_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-interruption-note-%d" (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Filename.concat dir "progress.md"

let remove_if_exists path = if Sys.file_exists path then Sys.remove path

let write_text path text =
  Out_channel.with_open_text path (fun oc -> output_string oc text)

let read_snapshot path =
  match MP.progress_snapshot_cache_of_text (In_channel.with_open_text path In_channel.input_all) with
  | Some cache -> cache.MP.snapshot
  | None -> Alcotest.fail "progress.md did not parse back into a snapshot"

let augment path =
  P.augment_progress_with_interruption_note
    ~progress_path:path
    ~generation:3
    ~updated_at:"2026-07-07T12:00:00Z"
    ~keeper_name:"note-keeper"

let test_note_written_when_no_progress_file () =
  let path = tmp_progress_path () in
  remove_if_exists path;
  augment path;
  let snapshot = read_snapshot path in
  check bool "note recorded as open question" true
    (List.mem P.no_state_interruption_note snapshot.MP.open_questions)

let test_existing_forward_content_survives () =
  let path = tmp_progress_path () in
  remove_if_exists path;
  let prior =
    {
      MP.empty_keeper_state_snapshot with
      MP.next_summary = Some "wire parser to store";
      MP.open_questions = [ "is the fixture stable?" ];
    }
  in
  (match
     MP.write_progress_snapshot_path ~path ~generation:3
       ~updated_at:"2026-07-07T11:00:00Z" prior
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("fixture write failed: " ^ e));
  augment path;
  let snapshot = read_snapshot path in
  check (option string) "prior next summary preserved"
    (Some "wire parser to store") snapshot.MP.next_summary;
  check bool "prior open question preserved" true
    (List.mem "is the fixture stable?" snapshot.MP.open_questions);
  check bool "note added" true
    (List.mem P.no_state_interruption_note snapshot.MP.open_questions)

let test_consecutive_turns_do_not_stack_duplicates () =
  let path = tmp_progress_path () in
  remove_if_exists path;
  augment path;
  augment path;
  augment path;
  let snapshot = read_snapshot path in
  let occurrences =
    List.length
      (List.filter
         (String.equal P.no_state_interruption_note)
         snapshot.MP.open_questions)
  in
  check int "note appears exactly once" 1 occurrences

let test_malformed_progress_is_not_overwritten () =
  let path = tmp_progress_path () in
  remove_if_exists path;
  let malformed = "not a progress snapshot\n" in
  write_text path malformed;
  augment path;
  check string "malformed progress left untouched" malformed
    (In_channel.with_open_text path In_channel.input_all)

let () =
  run "keeper_post_turn_interruption_note"
    [
      ( "interruption note",
        [
          test_case "written when no progress file exists" `Quick
            test_note_written_when_no_progress_file;
          test_case "existing forward content survives" `Quick
            test_existing_forward_content_survives;
          test_case "consecutive no-STATE turns dedupe" `Quick
            test_consecutive_turns_do_not_stack_duplicates;
          test_case "malformed progress is not overwritten" `Quick
            test_malformed_progress_is_not_overwritten;
        ] );
    ]
