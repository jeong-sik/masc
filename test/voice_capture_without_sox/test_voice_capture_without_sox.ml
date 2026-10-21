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

(* A fake sox toolset in a directory PATH points at. [rec] writes nothing and
   dies with a line on stderr; [play] answers the tone calls. The capture
   hands its child the parent's environment plus AUDIODEV, so the directory
   on PATH is the only place the test reaches in, and no microphone exists on
   the machine running this. The stderr line names $AUDIODEV, so an
   assertion on the reported reason doubles as proof the device traveled. *)
let with_fake_tools f =
  with_empty_dir
  @@ fun dir ->
  let write name contents =
    let path = Filename.concat dir name in
    let channel = open_out_gen [ Open_wronly; Open_creat ] 0o755 path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel contents)
  in
  write "play" {|#!/bin/sh
exit 0
|};
  write "rec" {|#!/bin/sh
echo "rec fail $AUDIODEV: fifo not found" >&2
exit 1
|};
  (* The scripts exist only while PATH points here; [with_empty_dir] rmdirs,
     so they go before [f] returns. *)
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun name ->
           try Sys.remove (Filename.concat dir name) with
           | Sys_error _ -> ())
        [ "play"; "rec" ])
    (fun () -> f dir)

(* The one harness body behind both reasons: a fresh base path, the fake
   tools on PATH, and one capture run through the real config, tone, recorder
   and watcher path. *)
let capture_error ~audio_device =
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
  with_fake_tools
  @@ fun dir ->
  with_path dir
    (fun () ->
       match
         Masc.Voice_bridge.record_and_transcribe
           ~agent_id:"tester"
           ?audio_device
           ~timeout_sec:2.0
           ()
       with
       | Ok _ -> Alcotest.fail "a fake recorder that exits 1 must not succeed"
       | Error message -> message)

let test_a_failed_recorder_reports_its_own_reason () =
  let message = capture_error ~audio_device:None in
  Alcotest.(check bool)
    (Printf.sprintf "the code stays when sox said nothing about a device (%s)" message)
    true
    (contains ~needle:"rec exit 1" message);
  Alcotest.(check bool)
    (Printf.sprintf "the recorder's stderr is the reason (%s)" message)
    true
    (contains ~needle:"rec fail : fifo not found" message);
  Alcotest.(check bool)
    (Printf.sprintf "no device was picked, so none is named (%s)" message)
    false
    (contains ~needle:"the device picked" message)

let test_a_picked_device_travels_and_is_named_on_failure () =
  let message = capture_error ~audio_device:(Some "picked-mic") in
  Alcotest.(check bool)
    (Printf.sprintf "the recorder saw the device as AUDIODEV (%s)" message)
    true
    (contains ~needle:"rec fail picked-mic" message);
  Alcotest.(check bool)
    (Printf.sprintf "the failure names the device picked (%s)" message)
    true
    (contains ~needle:"the device picked: picked-mic" message);
  Alcotest.(check bool)
    (Printf.sprintf "a recorder that ran is not called missing (%s)" message)
    false
    (contains ~needle:"not installed" message)

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
    ; ( "the recorder fails"
      , [ Alcotest.test_case "a failed recorder reports its own reason" `Quick
            test_a_failed_recorder_reports_its_own_reason
        ; Alcotest.test_case "a picked device travels and is named on failure" `Quick
            test_a_picked_device_travels_and_is_named_on_failure
        ] )
    ]
