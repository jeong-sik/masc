module Capture = Process_output_capture
module Publish = Masc.Keeper_execute_output_files
module Redaction = Masc.Keeper_secret_redaction

let stdout = "publisher stdout proof — 한글\n"
let stderr = "publisher stderr proof\n"

(* The ceiling a call gets when no lane widened its projection: the Execute
   descriptor's own [Store_above] default. *)
let default_ceiling = Tool_output.inline_ceiling_bytes Tool_output.default_model_projection

let complete_path expected = function
  | Capture.Complete_file { path; byte_length } ->
    Alcotest.(check int) "EOF receipt counts the actual child bytes"
      (String.length expected) byte_length;
    path
  | Capture.Incomplete_file _ -> Alcotest.fail "child stream did not reach EOF"
  | Capture.Capture_failed { message; _ } -> Alcotest.fail message

let with_process_output ?(stdout = stdout) ?(stderr = stderr) ?(pool = false) ?secret f =
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
        let additional_secret_files = match secret with
          | None -> []
          | Some value ->
            let path = Filename.concat base_path "publication-secret.txt" in
            Out_channel.with_open_bin path (fun channel -> output_string channel value);
            [ path ]
        in
        let redaction =
          Redaction.snapshot_with_additional_secret_files
            ~redact_identity_scalars:false ~additional_secret_files
            ~base_path ~keeper_name:"output-publication-fixture"
        in
        let run () = f ~base_path ~redaction ~stdout_path ~stderr_path files in
        if pool then
          Eio.Switch.run (fun sw ->
            let worker = Domain_pool.create ~sw ~domain_count:1
                (Eio.Stdenv.domain_mgr env) in
            let previous_pool = Domain_pool_ref.get () in
            Domain_pool_ref.set worker;
            Eio.Switch.on_release sw (fun () ->
              match previous_pool with
              | Some previous -> Domain_pool_ref.set previous
              | None -> Domain_pool_ref.clear_for_tests ());
            run ())
        else run ())))

let test_changed_eof_source_is_not_published () =
  with_process_output (fun ~base_path ~redaction ~stdout_path ~stderr_path files ->
    Unix.truncate stdout_path 1;
    (match Publish.publish ~inline_ceiling_bytes:default_ceiling ~base_path ~redaction files with
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
      match Publish.publish ~inline_ceiling_bytes:default_ceiling ~base_path ~redaction files with
      | Ok publication -> publication
      | Error error -> Alcotest.fail (Publish.error_to_string error)
    in
    Alcotest.(check bool) "complete output is explicitly marked" true
      (List.assoc_opt "output_completeness" publication.fields = Some (`String "complete"));
    Alcotest.(check int) "compared size is the published combined stream"
      (String.length stdout + String.length stderr)
      publication.compared_output_bytes;
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

(* ── Lane ceiling ─────────────────────────────────────────────────── *)

let claude_lane =
  Runtime_execution.Claude_code
    { cli_path = "claude"; account_home = None; model = None; timeout_s = 1.0 }

let codex_lane =
  Runtime_execution.Codex_app_server
    { cli_path = "codex"; account_home = None; model = None; timeout_s = 1.0 }

let antigravity_lane =
  Runtime_execution.Antigravity_cli
    { cli_path = "agy"
    ; model = "fixture"
    ; agent = None
    ; effort = None
    ; oauth_source = "fixture"
    ; timeout_s = 1.0
    ; add_dirs = []
    }

(* The ceiling of the projection the Keeper tool bundle builds for an
   Official-client lane: [Store_above] at that lane's inline ceiling. *)
let lane_ceiling lane =
  Tool_output.inline_ceiling_bytes
    (Tool_output.Store_above
       { threshold_bytes = Runtime_execution.tool_result_inline_ceiling_bytes lane })

let payload bytes =
  let line = "execute lane ceiling fixture 0123456789abcdefghijklmnopqrstuvwxyz\n" in
  String.init bytes (fun index -> line.[index mod String.length line])

let publish_payload ~lane bytes check_fields =
  let payload = payload bytes in
  with_process_output ~stdout:payload ~stderr:"" (fun ~base_path ~redaction ~stdout_path:_ ~stderr_path:_ files ->
    match Publish.publish ~inline_ceiling_bytes:(lane_ceiling lane) ~base_path ~redaction files with
    | Error error -> Alcotest.fail (Publish.error_to_string error)
    | Ok publication ->
      Alcotest.(check int) "compared bytes match the redacted stream"
        (String.length payload) publication.compared_output_bytes;
      check_fields ~base_path ~payload publication.Publish.fields)

let blob_bytes ~base_path field fields =
  match List.assoc_opt field fields with
  | None -> Alcotest.failf "%s is missing" field
  | Some reference ->
    let sha256 =
      Yojson.Safe.Util.(reference |> member "_blob" |> member "sha256" |> to_string)
    in
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256 with
     | Ok (Some bytes) -> bytes
     | Ok None -> Alcotest.failf "%s names a blob the store does not hold" field
     | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error))

(* The child can emit binary bytes or byte-cut UTF-8 even under the inline
   ceiling. Its result must cross JSON transport without losing the evidence. *)
let test_non_utf8_child_output_is_preserved () =
  let stdout = "한글 intact\n" ^ "\x89PNG\r\n\x1a\n" in
  let stderr = "cut Korean: \xed\x95" in
  with_process_output ~stdout ~stderr ~pool:true (fun ~base_path ~redaction ~stdout_path:_ ~stderr_path:_ files ->
    match Publish.publish ~inline_ceiling_bytes:default_ceiling ~base_path ~redaction files with
    | Error error -> Alcotest.fail (Publish.error_to_string error)
    | Ok publication ->
      let fields = publication.Publish.fields in
      let wire = Yojson.Safe.to_string (`Assoc fields) in
      Alcotest.(check bool) "JSON transport contains only valid UTF-8" true
        (String_util.is_valid_utf8 wire);
      ignore (Yojson.Safe.from_string wire);
      Alcotest.(check bool) "binary output is not misrepresented as inline text" false
        (List.mem_assoc "output" fields);
      Alcotest.(check string) "combined bytes remain available" (stdout ^ stderr)
        (blob_bytes ~base_path "output_artifact" fields);
      Alcotest.(check string) "stdout remains byte-identical" stdout
        (blob_bytes ~base_path "stdout_artifact" fields);
      Alcotest.(check string) "stderr retains its partial character" stderr
        (blob_bytes ~base_path "stderr_artifact" fields);
      publication.release_sources ())

let test_worker_publication_preserves_secret_snapshot () =
  let secret = "publication-exact-secret-value" in
  with_process_output ~stdout:(secret ^ "\n") ~stderr:(secret ^ "\n")
    ~pool:true ~secret (fun ~base_path ~redaction ~stdout_path:_ ~stderr_path:_ files ->
      Alcotest.(check string) "caller has already matched the snapshot"
        "[REDACTED]" (Redaction.redact_text redaction secret);
      match Publish.publish ~inline_ceiling_bytes:0 ~base_path ~redaction files with
      | Error error -> Alcotest.fail (Publish.error_to_string error)
      | Ok publication ->
        let fields = publication.Publish.fields in
        Alcotest.(check string) "worker redacts both captured streams"
          "[REDACTED]\n[REDACTED]\n"
          (blob_bytes ~base_path "output_artifact" fields);
        Alcotest.(check string) "caller snapshot remains usable"
          "[REDACTED]" (Redaction.redact_text redaction secret);
        publication.release_sources ())

let test_claude_lane_returns_20000_bytes_inline () =
  publish_payload ~lane:claude_lane 20_000 (fun ~base_path:_ ~payload fields ->
    Alcotest.(check bool) "20,000 bytes come back inline on the Claude Code lane" true
      (List.assoc_opt "output" fields = Some (`String payload));
    Alcotest.(check bool) "nothing was stored as a blob" false
      (List.mem_assoc "output_artifact" fields))

let test_claude_lane_stores_40000_bytes_byte_identical () =
  publish_payload ~lane:claude_lane 40_000 (fun ~base_path ~payload fields ->
    Alcotest.(check bool) "40,000 bytes are not inlined" false
      (List.mem_assoc "output" fields);
    Alcotest.(check string) "the stored output blob is the child's bytes" payload
      (blob_bytes ~base_path "output_artifact" fields);
    Alcotest.(check string) "the stored stdout blob is the child's bytes" payload
      (blob_bytes ~base_path "stdout_artifact" fields))

let test_narrow_lanes_still_store_20000_bytes () =
  List.iter
    (fun (name, lane) ->
      publish_payload ~lane 20_000 (fun ~base_path ~payload fields ->
        Alcotest.(check bool) (name ^ " does not inline 20,000 bytes") false
          (List.mem_assoc "output" fields);
        Alcotest.(check string) (name ^ " stores the child's bytes") payload
          (blob_bytes ~base_path "output_artifact" fields)))
    [ "Codex", codex_lane; "Antigravity", antigravity_lane ]

let () =
  Alcotest.run "Keeper Execute output publication"
    [ "actual child output",
      [ Alcotest.test_case "stale EOF source cannot become complete output" `Quick
          test_changed_eof_source_is_not_published
      ; Alcotest.test_case "publication waits for the caller to release sources" `Quick
          test_publication_retains_sources_until_release
      ; Alcotest.test_case "worker publication preserves captured secret values" `Quick
          test_worker_publication_preserves_secret_snapshot
      ; Alcotest.test_case "non-UTF-8 child output survives JSON transport" `Quick
          test_non_utf8_child_output_is_preserved
      ]
    ; "lane ceiling",
      [ Alcotest.test_case "Claude Code lane returns 20,000 bytes inline" `Quick
          test_claude_lane_returns_20000_bytes_inline
      ; Alcotest.test_case "Claude Code lane stores 40,000 bytes byte-identical" `Quick
          test_claude_lane_stores_40000_bytes_byte_identical
      ; Alcotest.test_case "Codex and Antigravity lanes still store 20,000 bytes" `Quick
          test_narrow_lanes_still_store_20000_bytes
      ]
    ]
