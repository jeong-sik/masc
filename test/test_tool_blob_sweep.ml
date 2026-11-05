(** RFC-0499 layer one: the in-server sweep counts what layer two would
    delete and records it, and deletes nothing. *)

module B = Tool_blob_store
module O = Tool_output
module S = Tool_blob_sweep

let board_posts_file = Masc_board_handlers.Board_paths.posts_file

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_sweep_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* The touch ledger belongs to the process. Two rotations empty both
   generations, so each case starts from no marks. *)
let forget_marks () =
  B.rotate_touches ();
  B.rotate_touches ()

let put store bytes =
  let (O.Stored reference) = B.put store ~bytes ~mime:"text/plain" in
  reference

let blob_path store (reference : O.artifact_ref) =
  Filename.concat
    (Filename.concat (B.root_dir store) (String.sub reference.sha256 0 2))
    reference.sha256

let set_mtime store reference at = Unix.utimes (blob_path store reference) at at

(* One durable consumer: a Keeper session history line per reference. *)
let reference_in_history ~base_path references =
  let history =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "keepers/keeper-a/sessions/history.jsonl"
  in
  Fs_compat.mkdir_p (Filename.dirname history);
  Fs_compat.save_file
    history
    (String.concat
       ""
       (List.map
          (fun reference ->
             Yojson.Safe.to_string
               (`Assoc
                 [ "consumer", `String "Tool_bridge"
                 ; "output_ref", `String (O.encode_for_agent_core (O.Stored reference))
                 ])
             ^ "\n")
          references))

let observe_ok ~base_path =
  match S.observe ~base_path ~board_posts_file with
  | Ok report -> report
  | Error error -> Alcotest.failf "sweep failed: %s" (S.error_to_string error)

let fetch_exists store (reference : O.artifact_ref) =
  match B.fetch store ~sha256:reference.sha256 with
  | Ok value -> Option.is_some value
  | Error error -> Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let long_ago () = Unix.gettimeofday () -. (3.0 *. Masc_time_constants.day)

let test_first_scan_records_candidates_and_waits_a_day () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live = put store "first scan live output" in
      let dead = put store "first scan dead output" in
      reference_in_history ~base_path [ live ];
      forget_marks ();
      (match S.schedule ~base_path ~now:(Unix.gettimeofday ()) with
       | Ok S.Due -> ()
       | Ok (S.Next_at _) -> Alcotest.fail "no scan has opened, so a scan is due"
       | Error error -> Alcotest.fail (S.error_to_string error));
      let report = observe_ok ~base_path in
      Alcotest.(check int) "one live digest" 1 report.live_digests;
      Alcotest.(check int) "two blobs" 2 report.blobs;
      Alcotest.(check int) "one candidate" 1 report.candidates;
      Alcotest.(check int) "nothing deletable without a previous record" 0 report.deletable;
      (match report.previous with
       | S.No_previous_record -> ()
       | S.Previous_record_invalid _ | S.Compared_with_previous _ ->
         Alcotest.fail "the first scan has no previous record");
      Alcotest.(check bool) "record written" true (Sys.file_exists (S.record_path ~base_path));
      Alcotest.(check bool) "candidate still readable" true (fetch_exists store dead);
      let opened = report.scan_started_at in
      (match S.schedule ~base_path ~now:(opened +. 1.0) with
       | Ok (S.Next_at at) ->
         Alcotest.(check (float 0.001)) "next scan a day after this one opened"
           (opened +. Masc_time_constants.day) at
       | Ok S.Due -> Alcotest.fail "a scan opened a second ago"
       | Error error -> Alcotest.fail (S.error_to_string error));
      match S.schedule ~base_path ~now:(opened +. Masc_time_constants.day) with
      | Ok S.Due -> ()
      | Ok (S.Next_at _) -> Alcotest.fail "a day has passed since the scan opened"
      | Error error -> Alcotest.fail (S.error_to_string error))

let test_second_scan_leaves_out_marked_and_rewritten_blobs () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live = put store "second scan live output" in
      let stale = put store "second scan stale output" in
      let read_since = put store "second scan output read since" in
      let written_since = put store "second scan output written since" in
      reference_in_history ~base_path [ live ];
      List.iter (fun reference -> set_mtime store reference (long_ago ()))
        [ stale; read_since; written_since ];
      forget_marks ();
      let first = observe_ok ~base_path in
      Alcotest.(check int) "three candidates" 3 first.candidates;
      Alcotest.(check bool) "read marks the blob" true (fetch_exists store read_since);
      set_mtime store written_since (first.scan_started_at +. 1.0);
      let second = observe_ok ~base_path in
      Alcotest.(check int) "three candidates again" 3 second.candidates;
      Alcotest.(check int) "only the stale blob is deletable" 1 second.deletable;
      Alcotest.(check int) "its bytes" (String.length "second scan stale output")
        second.deletable_bytes;
      Alcotest.(check int) "every candidate was statable" 0 second.unstatable;
      Alcotest.(check bool) "layer one deletes nothing" true (fetch_exists store stale))

let test_previous_deletable_now_live_is_classified () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let put_again = put store "classified output put again" in
      let read_again = put store "classified output read again" in
      let left_alone = put store "classified output left alone" in
      let previous_deletable = [ put_again; read_again; left_alone ] in
      List.iter (fun reference -> set_mtime store reference (long_ago ())) previous_deletable;
      forget_marks ();
      let _first = observe_ok ~base_path in
      let second = observe_ok ~base_path in
      Alcotest.(check int) "all three deletable" 3 second.deletable;
      (* After the record names them deletable, a durable consumer takes all
         three, and the process touches two of them. *)
      reference_in_history ~base_path previous_deletable;
      let (_ : O.t) = B.put store ~bytes:"classified output put again" ~mime:"text/plain" in
      Alcotest.(check bool) "read" true (fetch_exists store read_again);
      let third = observe_ok ~base_path in
      match third.previous with
      | S.No_previous_record | S.Previous_record_invalid _ ->
        Alcotest.fail "the third scan compares with the second"
      | S.Compared_with_previous previous ->
        Alcotest.(check int) "previous deletable" 3 previous.previous_deletable;
        Alcotest.(check int) "one of them read" 1 previous.previous_deletable_read;
        Alcotest.(check int) "put again: the file would be written back" 1
          previous.now_live.rewritten;
        Alcotest.(check int) "read only: the fetch would fail" 1 previous.now_live.read_only;
        Alcotest.(check int) "left alone: a reference without its file" 1
          previous.now_live.untouched;
        Alcotest.(check int) "no candidates now" 0 third.candidates;
        let record = In_channel.with_open_bin (S.record_path ~base_path) In_channel.input_all in
        Alcotest.(check bool) "the record names the reference left without a file" true
          (List.mem ("u " ^ left_alone.sha256) (String.split_on_char '\n' record)))

let test_invalid_record_is_replaced_and_compares_nothing () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let stale = put store "output older than an invalid record" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let _first = observe_ok ~base_path in
      Fs_compat.save_file (S.record_path ~base_path) "not a candidate record\n";
      let replaced = observe_ok ~base_path in
      (match replaced.previous with
       | S.Previous_record_invalid { line; detail = _ } ->
         Alcotest.(check int) "the header line is the invalid one" 1 line
       | S.No_previous_record | S.Compared_with_previous _ ->
         Alcotest.fail "an invalid record is reported as invalid");
      Alcotest.(check int) "nothing deletable without a comparison" 0 replaced.deletable;
      let next = observe_ok ~base_path in
      match next.previous with
      | S.Compared_with_previous _ ->
        Alcotest.(check int) "the replaced record counts as the previous scan" 1 next.deletable
      | S.No_previous_record | S.Previous_record_invalid _ ->
        Alcotest.fail "the scan after a replacement compares with it")

let test_failed_scan_keeps_the_marks () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      forget_marks ();
      let marked = put store "output marked before a failed scan" in
      let _first = observe_ok ~base_path in
      (* A directory where the record belongs cannot be read or replaced. *)
      let record = S.record_path ~base_path in
      Sys.remove record;
      Unix.mkdir record 0o755;
      (match S.observe ~base_path ~board_posts_file with
       | Error (S.Record_unreadable _) -> ()
       | Error
           (( S.Scan_failed _ | S.Listing_failed _ | S.Record_write_failed _
            | S.Marker_failed _ ) as error) ->
         Alcotest.failf "expected an unreadable record: %s" (S.error_to_string error)
       | Ok _ -> Alcotest.fail "a directory is not a record");
      Alcotest.(check bool) "the mark survives the failed scan" true
        (Option.is_some (B.touch_of (B.observe_touches ()) ~sha256:marked.sha256)))

let () =
  Alcotest.run "tool_blob_sweep"
    [ ( "sweep"
      , [ Alcotest.test_case "first scan records candidates and waits a day" `Quick
            test_first_scan_records_candidates_and_waits_a_day
        ; Alcotest.test_case "second scan leaves out marked and rewritten blobs" `Quick
            test_second_scan_leaves_out_marked_and_rewritten_blobs
        ; Alcotest.test_case "previous deletable now live is classified" `Quick
            test_previous_deletable_now_live_is_classified
        ; Alcotest.test_case "invalid record is replaced and compares nothing" `Quick
            test_invalid_record_is_replaced_and_compares_nothing
        ; Alcotest.test_case "failed scan keeps the marks" `Quick
            test_failed_scan_keeps_the_marks
        ] )
    ]
