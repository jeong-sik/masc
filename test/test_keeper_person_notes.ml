(* RFC-0229 P1 — Keeper_person_notes store: append-only rows,
   fold-at-read latest-wins, blank-note tombstone. *)

module N = Masc.Keeper_person_notes

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_base_dir f =
  let base_dir = temp_base_path "keeper-person-notes" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () -> f base_dir)

let keeper_name = "person-notes-keeper"

let test_latest_note_wins () =
  with_base_dir (fun base_dir ->
      N.set_note ~base_dir ~keeper_name ~speaker_id:"111"
        ~note:"first impression" ();
      N.set_note ~base_dir ~keeper_name ~speaker_id:"222" ~note:"second person"
        ();
      N.set_note ~base_dir ~keeper_name ~speaker_id:"111"
        ~note:"updated impression" ();
      let notes = N.notes ~base_dir ~keeper_name in
      Alcotest.(check int) "two speakers" 2 (List.length notes);
      Alcotest.(check (option string))
        "latest wins" (Some "updated impression")
        (List.assoc_opt "111" notes);
      Alcotest.(check (option string))
        "other intact" (Some "second person")
        (List.assoc_opt "222" notes))

let test_blank_note_is_tombstone () =
  with_base_dir (fun base_dir ->
      N.set_note ~base_dir ~keeper_name ~speaker_id:"111" ~note:"to be erased"
        ();
      N.set_note ~base_dir ~keeper_name ~speaker_id:"111" ~note:"" ();
      Alcotest.(check int)
        "tombstoned entry absent" 0
        (List.length (N.notes ~base_dir ~keeper_name)))

let test_missing_file_is_empty () =
  with_base_dir (fun base_dir ->
      Alcotest.(check int)
        "no file, no notes" 0
        (List.length (N.notes ~base_dir ~keeper_name)))

let () =
  Alcotest.run "keeper_person_notes"
    [
      ( "fold",
        [
          Alcotest.test_case "latest note wins per speaker" `Quick
            test_latest_note_wins;
          Alcotest.test_case "blank note tombstones" `Quick
            test_blank_note_is_tombstone;
          Alcotest.test_case "missing file is empty" `Quick
            test_missing_file_is_empty;
        ] );
    ]
