(* What a capture says on a machine that has no sox.

   masc records with sox's rec. A fresh mac has no sox, and the recorder used
   to answer "rec exit 127": a number, and one the process runner also uses
   for a denied permission or a working directory that would not open, so
   reading it as "not installed" would have been wrong for some of them.

   This runs the real capture -- config, tones, recorder, watcher -- with PATH
   pointed at an empty directory. The recorder is refused before a process
   exists, so no microphone is opened on the machine running the test, and the
   answer does not depend on whether that machine happens to have sox. *)

let with_path path f =
  let prior = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" path;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv "PATH" value
      | None -> Unix.putenv "PATH" "")
    f

let with_empty_dir f =
  let dir = Filename.temp_file "masc-no-sox-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir dir) (fun () -> f dir)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let test_a_capture_without_sox_says_what_to_install () =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  with_empty_dir
  @@ fun base ->
  (* A fresh base path, so the capture runs on the measured defaults rather
     than on whatever voice config the machine running this has. *)
  Unix.putenv "MASC_BASE_PATH" base;
  with_empty_dir
  @@ fun empty_path ->
  let answer =
    with_path empty_path (fun () ->
      Masc.Voice_bridge.record_and_transcribe ~agent_id:"tester" ~timeout_sec:2.0 ())
  in
  match answer with
  | Ok _ -> Alcotest.fail "a capture with no recorder on PATH must not succeed"
  | Error message ->
    Alcotest.(check bool)
      (Printf.sprintf "names the missing recorder (%s)" message)
      true
      (contains ~needle:"rec is not installed" message);
    Alcotest.(check bool)
      "and says where the install is named"
      true
      (contains ~needle:"prerequisite-actions whisper" message);
    Alcotest.(check bool)
      "not the bare exit code it used to be"
      false
      (contains ~needle:"exit 127" message)

(* Only a missing executable is given a cause. A refusal of any other kind
   keeps the runner's own sentence, because naming sox for a permission error
   would send the operator to install something they already have. *)
let test_other_refusals_keep_their_own_reason () =
  let message =
    Masc.Voice_bridge.recorder_refusal_message
      (Process_eio.Spawn_failed { executable = "rec"; error = Unix.EACCES })
  in
  Alcotest.(check bool)
    (Printf.sprintf "no install advice for a denied spawn (%s)" message)
    false
    (contains ~needle:"not installed" message);
  Alcotest.(check bool)
    "the runner's reason is kept"
    true
    (contains ~needle:(Unix.error_message Unix.EACCES) message)

let () =
  Alcotest.run
    "voice capture without sox"
    [ ( "the recorder is missing"
      , [ Alcotest.test_case "a capture without sox says what to install" `Quick
            test_a_capture_without_sox_says_what_to_install
        ; Alcotest.test_case "other refusals keep their own reason" `Quick
            test_other_refusals_keep_their_own_reason
        ] )
    ]
