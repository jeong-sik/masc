module Capture = Process_output_capture
module Publish = Masc.Keeper_execute_output_files
module Redaction = Masc.Keeper_secret_redaction

let stdout = "publisher stdout proof\n"
let stderr = "publisher stderr proof\n"

let complete_path expected = function
  | Capture.Complete_file { path; byte_length } ->
    Alcotest.(check int) "EOF receipt counts the actual child bytes"
      (String.length expected) byte_length;
    path
  | Capture.Incomplete_file _ -> Alcotest.fail "child stream did not reach EOF"
  | Capture.Capture_failed { message; _ } -> Alcotest.fail message

let with_process_output f =
  let base_path = Filename.temp_dir "keeper-output-publication-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Process_eio.init ~cwd_default:env#fs ~proc_mgr:env#process_mgr ~clock:env#clock;
      Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
        let capture_dir = Publish.capture_directory ~base_path in
        let (status, _, _), files =
          Capture.with_capture ~capture_dir (fun output_capture ->
            Process_eio.run_argv_with_status_split_streaming
              ~output_capture ~cwd:base_path
              ~env:[| "PATH=/usr/bin:/bin"; "LANG=C" |]
              ~on_stdout_chunk:(fun _ -> ()) ~on_stderr_chunk:(fun _ -> ())
              [ "/bin/sh"; "-c"; "printf '%s' \"$1\"; printf '%s' \"$2\" >&2; exit 17"
              ; "publication-fixture"; stdout; stderr ])
        in
        (match status with
         | Unix.WEXITED 17 -> ()
         | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
           Alcotest.fail "the real child's nonzero exit was changed");
        let stdout_path = complete_path stdout files.stdout in
        let stderr_path = complete_path stderr files.stderr in
        let redaction =
          Redaction.snapshot_with_additional_secret_files
            ~redact_identity_scalars:false ~additional_secret_files:[]
            ~base_path ~keeper_name:"output-publication-fixture"
        in
        f ~base_path ~redaction ~stdout_path ~stderr_path files)))

let test_changed_eof_source_is_not_published () =
  with_process_output (fun ~base_path ~redaction ~stdout_path ~stderr_path files ->
    Unix.truncate stdout_path 1;
    (match Publish.publish ~base_path ~redaction files with
     | Error (Publish.Persistence_failed _) -> ()
     | Error error -> Alcotest.fail (Publish.error_to_string error)
     | Ok _ -> Alcotest.fail "a stale EOF receipt became complete output");
    Alcotest.(check bool) "failed publication retains the changed source" true
      (Sys.file_exists stdout_path);
    Alcotest.(check int) "publication did not replace the changed evidence" 1
      (Unix.stat stdout_path).st_size;
    Alcotest.(check string) "failed publication retains the untouched stream" stderr
      (In_channel.with_open_bin stderr_path In_channel.input_all);
    Alcotest.(check (list string)) "failed publication issued no artifact address" []
      (Tool_blob_store.list_all (Tool_blob_store.create ~base_path)))

let test_publication_retains_sources_until_release () =
  with_process_output (fun ~base_path ~redaction ~stdout_path ~stderr_path files ->
    let publication =
      match Publish.publish ~base_path ~redaction files with
      | Ok publication -> publication
      | Error error -> Alcotest.fail (Publish.error_to_string error)
    in
    Alcotest.(check bool) "complete output is explicitly marked" true
      (List.assoc_opt "output_completeness" publication.fields = Some (`String "complete"));
    Alcotest.(check bool) "published output preserves both child streams" true
      (List.assoc_opt "output" publication.fields = Some (`String (stdout ^ stderr)));
    Alcotest.(check string) "stdout survives publication awaiting caller commit" stdout
      (In_channel.with_open_bin stdout_path In_channel.input_all);
    Alcotest.(check string) "stderr survives publication awaiting caller commit" stderr
      (In_channel.with_open_bin stderr_path In_channel.input_all);
    publication.release_sources ();
    Alcotest.(check bool) "explicit release removes stdout" false
      (Sys.file_exists stdout_path);
    Alcotest.(check bool) "explicit release removes stderr" false
      (Sys.file_exists stderr_path))

let () =
  Alcotest.run "Keeper Execute output publication"
    [ "actual child output",
      [ Alcotest.test_case "stale EOF source cannot become complete output" `Quick
          test_changed_eof_source_is_not_published
      ; Alcotest.test_case "publication waits for the caller to release sources" `Quick
          test_publication_retains_sources_until_release
      ]
    ]
