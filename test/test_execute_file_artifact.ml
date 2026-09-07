module B = Tool_blob_store
module H = Digestif.SHA256

let with_directory f =
  let path = Filename.temp_file "execute-file-artifact-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)

(* Generate the expected digest while writing, without retaining the whole
   process output in the harness. Distinct prefixes detect crossed streams. *)
let write_source path prefix =
  let block = String.init 8192 (fun i -> Char.chr (i mod 251)) in
  let capture_ceiling =
    Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes
  in
  let blocks = 1 + (2 * capture_ceiling / String.length block) in
  let digest = ref (H.feed_string H.empty prefix) in
  Out_channel.with_open_bin path (fun channel ->
    output_string channel prefix;
    for _ = 1 to blocks do
      output_string channel block;
      digest := H.feed_string !digest block
    done);
  H.(to_hex (get !digest)), String.length prefix + blocks * String.length block

let verify_pages store (artifact : Tool_output.artifact_ref) ~expected_sha ~expected_bytes =
  Alcotest.(check string) "stored address is the whole source digest"
    expected_sha artifact.sha256;
  Alcotest.(check int) "stored length includes the middle of the output"
    expected_bytes artifact.bytes;
  let rec read offset digest =
    match B.fetch_range store ~sha256:artifact.sha256 ~offset ~max_bytes:65536 with
    | Error error -> Alcotest.fail (B.fetch_error_to_string error)
    | Ok None -> Alcotest.fail "durable artifact disappeared with its spool file"
    | Ok (Some page) ->
      Alcotest.(check int) "every page reports the full byte count"
        expected_bytes page.total_bytes;
      if String.length page.content = 0 then (
        Alcotest.(check int) "EOF follows all bytes" expected_bytes offset;
        Alcotest.(check string) "all pages reproduce the original digest"
          expected_sha H.(to_hex (get digest)))
      else
        read (offset + String.length page.content) (H.feed_string digest page.content)
  in
  read 0 H.empty

let test_process_output_survives_spool_removal exit_code () =
  with_directory (fun base_path ->
    let source_stdout = Filename.concat base_path "source.stdout" in
    let source_stderr = Filename.concat base_path "source.stderr" in
    let stdout_sha, stdout_bytes = write_source source_stdout "stdout\000\n" in
    let stderr_sha, stderr_bytes = write_source source_stderr "stderr\255\n" in
    let stdout_path = Filename.concat base_path "captured.stdout" in
    let stderr_path = Filename.concat base_path "captured.stderr" in
    Eio_main.run (fun env ->
      Process_eio.init ~cwd_default:env#fs ~proc_mgr:env#process_mgr ~clock:env#clock;
      Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
        let result =
          Process_eio.run_argv_with_redirects
            ~stdin:(Process_eio.From_string "")
            ~stdout:(Process_eio.Written_to { path = stdout_path; append = false })
            ~stderr:(Process_eio.Written_to { path = stderr_path; append = false })
            [ "/bin/sh"; "-c"; "cat \"$1\"; cat \"$2\" >&2; exit \"$3\""
            ; "output-fixture"; source_stdout; source_stderr; string_of_int exit_code
            ]
        in
        (match result with
         | Error message -> Alcotest.fail message
         | Ok (Unix.WEXITED actual, stdout, stderr) ->
           Alcotest.(check int) "the actual process exit survives" exit_code actual;
           Alcotest.(check string) "stdout lives in the file" "" stdout;
           Alcotest.(check string) "stderr lives in the file" "" stderr
         | Ok (Unix.WSIGNALED _, _, _) | Ok (Unix.WSTOPPED _, _, _) ->
           Alcotest.fail "the output fixture did not finish normally");
        let store = B.create ~base_path in
        let stdout_ref = B.put_file_durable store ~path:stdout_path ~mime:"application/octet-stream" in
        let stderr_ref = B.put_file_durable store ~path:stderr_path ~mime:"application/octet-stream" in
        Sys.remove stdout_path;
        Sys.remove stderr_path;
        Sys.remove source_stdout;
        Sys.remove source_stderr;
        let reopened = B.create ~base_path in
        verify_pages reopened stdout_ref ~expected_sha:stdout_sha ~expected_bytes:stdout_bytes;
        verify_pages reopened stderr_ref ~expected_sha:stderr_sha ~expected_bytes:stderr_bytes)))

let test_empty_file_is_a_real_artifact () =
  with_directory (fun base_path ->
    let path = Filename.concat base_path "empty" in
    Out_channel.with_open_bin path (fun _ -> ());
    let store = B.create ~base_path in
    let artifact = B.put_file_durable store ~path ~mime:"text/plain" in
    Sys.remove path;
    verify_pages store artifact ~expected_sha:H.(to_hex (digest_string "")) ~expected_bytes:0)

let test_changing_source_cannot_publish_the_old_address () =
  with_directory (fun base_path ->
    let path = Filename.concat base_path "changing-output" in
    let original = "before: unchanged file length\n" in
    let changed = "after!: unchanged file length\n" in
    let write bytes = Out_channel.with_open_bin path (fun c -> output_string c bytes) in
    write original;
    let store = B.create ~base_path in
    (match
       B.For_testing.put_file_durable store ~path ~mime:"text/plain"
         ~after_hash:(fun () -> write changed)
     with
     | _ -> Alcotest.fail "a changed source was published at its previous address"
     | exception Sys_error _ -> ());
    Alcotest.(check (list string)) "failed ingestion published no content address"
      [] (B.list_all store);
    let artifact = B.put_file_durable store ~path ~mime:"text/plain" in
    verify_pages store artifact ~expected_sha:H.(to_hex (digest_string changed))
      ~expected_bytes:(String.length changed))

let test_storage_failure_keeps_the_source_for_retry () =
  with_directory (fun base_path ->
    let path = Filename.concat base_path "completed-output" in
    let bytes = "the process already completed\n" in
    Out_channel.with_open_bin path (fun c -> output_string c bytes);
    let obstruction = Common.masc_dir_from_base_path ~base_path in
    Out_channel.with_open_bin obstruction (fun c -> output_string c "not a directory");
    let store = B.create ~base_path in
    (match B.put_file_durable store ~path ~mime:"text/plain" with
     | _ -> Alcotest.fail "storage failure returned a durable reference"
     | exception Sys_error _ -> ());
    Alcotest.(check bool) "the completed process output remains available" true
      (Sys.file_exists path);
    Sys.remove obstruction;
    let artifact = B.put_file_durable store ~path ~mime:"text/plain" in
    verify_pages store artifact ~expected_sha:H.(to_hex (digest_string bytes))
      ~expected_bytes:(String.length bytes))

let test_fifo_is_rejected_without_waiting_for_a_writer () =
  with_directory (fun base_path ->
    let path = Filename.concat base_path "not-a-completed-output" in
    Unix.mkfifo path 0o600;
    let store = B.create ~base_path in
    match B.put_file_durable store ~path ~mime:"text/plain" with
    | _ -> Alcotest.fail "a FIFO became a completed file artifact"
    | exception Sys_error _ -> ())

let () =
  Alcotest.run "Execute file artifacts"
    [ "whole output",
      [ Alcotest.test_case "successful process stdout and stderr" `Quick
          (test_process_output_survives_spool_removal 0)
      ; Alcotest.test_case "nonzero exit keeps both complete streams" `Quick
          (test_process_output_survives_spool_removal 17)
      ; Alcotest.test_case "empty file has a durable address" `Quick
          test_empty_file_is_a_real_artifact
      ; Alcotest.test_case "source mutation cannot publish a false digest" `Quick
          test_changing_source_cannot_publish_the_old_address
      ; Alcotest.test_case "storage retry reuses completed output" `Quick
          test_storage_failure_keeps_the_source_for_retry
      ; Alcotest.test_case "a pipe cannot block file ingestion" `Quick
          test_fifo_is_rejected_without_waiting_for_a_writer
      ]
    ]
