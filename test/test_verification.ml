(** Tests for Verification module *)

(* Mirage_crypto_rng is consumed by V.generate_id (#7544). *)
let () = Mirage_crypto_rng_unix.use_default ()

module V = Masc.Verification
module P = Masc.Otel_metric_store
module VS = Workspace_verification_store
module CU = Workspace_utils
module W = Workspace_core
module VP = Masc.Verification_protocol

let persistence_surface = "verification"

let persistence_counter reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)] ()

(* Initialize mirage-crypto-rng once (needed by Verification.generate_id). *)
let () = Mirage_crypto_rng_unix.use_default ()

let active_verifications_dir base_path =
  Filename.concat (CU.masc_dir_from_base_path ~base_path) "verifications"

let legacy_verifications_dir base_path =
  Filename.concat base_path "verifications"

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(** Use a temporary directory for each test *)
let with_temp_dir f =
  let dir = Filename.temp_dir "masc_verify_test" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_eio_temp_dir f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect
    ~finally:Fs_compat.clear_fs
    (fun () -> with_temp_dir f)

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop offset =
    if offset + needle_len > text_len then false
    else if String.sub text offset needle_len = needle then true
    else loop (offset + 1)
  in
  needle_len = 0 || loop 0

(* --- Criterion tests --- *)

let test_criterion_roundtrip () =
  let criteria = [
    V.Schema_match (`Assoc [("type", `String "string")]);
    V.Contains "hello";
    V.Not_contains "error";
    V.Custom "output should be helpful";
  ] in
  List.iter (fun c ->
    let json = V.criterion_to_yojson c in
    match V.criterion_of_yojson json with
    | Ok result ->
        Alcotest.(check bool) "criterion roundtrip" true
          (V.equal_criterion c result)
    | Error e -> Alcotest.fail e
  ) criteria

let test_criterion_of_yojson_errors () =
  let bad_cases = [
    (`String "not an object", "not object");
    (`Assoc [], "missing type");
    (`Assoc [("type", `String "banana")], "unknown type");
    (`Assoc [("type", `String "contains")], "contains missing value");
  ] in
  List.iter (fun (json, label) ->
    match V.criterion_of_yojson json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "%s should fail" label)
  ) bad_cases

(* --- Storage tests --- *)

let test_create_and_load () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"task-1"
        ~output:(`String "result") ~criteria:[V.Contains "result"]
        ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        Alcotest.(check bool) "persisted under .masc/verifications" true
          (Sys.file_exists
             (Filename.concat (active_verifications_dir base_path)
                (req.id ^ ".json")));
        match V.load_request base_path req.id with
        | Error e -> Alcotest.fail e
        | Ok loaded ->
            Alcotest.(check string) "id matches" req.id loaded.id;
            Alcotest.(check string) "task_id" "task-1" loaded.task_id;
            Alcotest.(check string) "worker" "claude" loaded.worker)

(* RFC-0221 §3.1: [delete_request] removes the record (compensation) and is
   idempotent — deleting a missing record is success, so a caller can compensate
   without first checking existence. *)
let test_delete_request () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"task-1"
        ~output:(`String "result") ~criteria:[V.Contains "result"]
        ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        let path =
          Filename.concat (active_verifications_dir base_path) (req.id ^ ".json")
        in
        Alcotest.(check bool) "record present before delete" true (Sys.file_exists path);
        (match V.delete_request base_path req.id with
         | Error e -> Alcotest.fail e
         | Ok () -> ());
        Alcotest.(check bool) "record gone after delete" false (Sys.file_exists path);
        (match V.delete_request base_path req.id with
         | Error e -> Alcotest.fail ("second delete must be idempotent Ok: " ^ e)
         | Ok () -> ());
        match V.load_request base_path req.id with
        | Ok _ -> Alcotest.fail "load after delete should report not-found"
        | Error _ -> ())

let test_list_requests () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let _ = V.create_request ~base_path ~task_id:"t2"
        ~output:`Null ~criteria:[] ~worker:"b" () in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "two requests" 2 (List.length reqs))

let test_list_requests_missing_dir_stays_quiet () =
  with_temp_dir (fun base_path ->
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_list_dir_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "no requests" 0 (List.length reqs);
    Alcotest.(check (float 0.1)) "missing dir does not increment metric"
      before
      (persistence_counter Safe_ops.persistence_read_drop_reason_list_dir_error))

let test_verifications_dir_resolves_active_store () =
  with_temp_dir (fun base_path ->
    let legacy_dir = legacy_verifications_dir base_path in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir "vrf-legacy.json")
      {|{"id":"vrf-legacy","task_id":"task-legacy"}|};
    let active_dir = active_verifications_dir base_path in
    let resolved = VS.verifications_dir base_path in
    Alcotest.(check string) "resolved active store" active_dir resolved;
    Alcotest.(check bool) "resolved path is not legacy root" false
      (String.equal legacy_dir resolved))

let test_request_path_ignores_legacy_root_store () =
  with_temp_dir (fun base_path ->
    let req_id = "vrf-shadowed" in
    let legacy_dir = legacy_verifications_dir base_path in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir (req_id ^ ".json"))
      {|{"id":"vrf-shadowed","task_id":"task-legacy"}|};
    Alcotest.(check string) "request path uses active store"
      (Filename.concat (active_verifications_dir base_path) (req_id ^ ".json"))
      (VS.request_path base_path req_id))

let test_list_requests_skips_bad_entries_with_metric () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let dir = active_verifications_dir base_path in
    Fs_compat.save_file (Filename.concat dir "broken.json") "{not-json";
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "only valid request returned" 1 (List.length reqs);
    Alcotest.(check (float 0.1)) "broken file increments metric" 1.0
      (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
       -. before))

let test_list_requests_ignores_legacy_only_stale_entries () =
  with_temp_dir (fun base_path ->
    let legacy_dir = legacy_verifications_dir base_path in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir "broken.json") "{not-json";
    Fs_compat.save_file (Filename.concat legacy_dir "vrf-foreign.json")
      {|{"id":"vrf-foreign","task_id":"t-foreign","evaluator":"oracle","overall_verdict":"approve"}|};
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "legacy-only store ignored" 0 (List.length reqs);
    Alcotest.(check (float 0.1)) "legacy-only stale files stay silent"
      before
      (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error))

let test_list_requests_ignores_legacy_root_entries () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let legacy_dir = legacy_verifications_dir base_path in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir "broken.json") "{not-json";
    Fs_compat.save_file (Filename.concat legacy_dir "vrf-foreign.json")
      {|{"id":"vrf-foreign","task_id":"t-foreign","evaluator":"oracle","overall_verdict":"approve"}|};
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "legacy root ignored" 1 (List.length reqs);
    Alcotest.(check (float 0.1)) "legacy root does not increment metric"
      before
      (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error))

let create_evidence_request ~base_path ~request_id ~artifact_path =
  let profile_path =
    Keeper_sandbox_config.keeper_toml_path
      ~base_path
      ~agent_name:"keeper-executor-agent"
  in
  Fs_compat.mkdir_p (Filename.dirname profile_path);
  Fs_compat.save_file profile_path "[keeper]\nsandbox_profile = \"docker\"\n";
  let submitted_evidence =
    match
      Playground_paths.parse_playground_file_path
        ~base_path
        ~abs_path:artifact_path
    with
    | Some { keeper_name = "executor"; relative_path } ->
      [ "artifact:" ^ relative_path; "note:executor summary" ]
    | Some _ | None ->
      [ "artifact:../outside-worker-playground"; "note:executor summary" ]
  in
  let evidence_snapshot =
    VS.snapshot_submitted_evidence_json
      ~base_path
      ~worker:"keeper-executor-agent"
      submitted_evidence
  in
  match
    V.create_request
      ~base_path
      ~request_id
      ~task_id:"task-001"
      ~output:
        (`Assoc
            [ "submitted_evidence", evidence_snapshot ])
      ~criteria:[ V.Custom "inspect artifact" ]
      ~worker:"keeper-executor-agent"
      ()
  with
  | Ok request -> request
  | Error detail -> Alcotest.fail detail

let write_keeper_profile ~base_path ~keeper_name ~sandbox_profile =
  let path =
    Keeper_sandbox_config.keeper_toml_path
      ~base_path
      ~agent_name:keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file
    path
    (Printf.sprintf "[keeper]\nsandbox_profile = %S\n" sandbox_profile)

let create_protocol_evidence_request ~base_path ~request_id ~evidence_refs =
  let config = W.default_config base_path in
  ignore (W.init config ~agent_name:None);
  ignore
    (W.add_task
       config
       ~title:"Produce typed verification evidence"
       ~priority:1
       ~description:"");
  let task =
    match (W.read_backlog config).tasks with
    | [ task ] -> task
    | tasks ->
      Alcotest.failf "expected one task, got %d" (List.length tasks)
  in
  (match
     VP.create_submit_request
       ~config
       ~task
       ~assignee:"keeper-executor-agent"
       ~verification_id:request_id
       ~evidence_refs
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  task

let inspect_evidence ?(task_id = "task-001")
    ?(task_worker = "keeper-executor-agent") ~base_path ~request_id
    () =
  VS.inspect_submitted_evidence_for_authority
    ~base_path
    ~request_id
    ~task_id
    ~task_worker
    ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })

let test_submitted_evidence_inspection_is_authority_scoped_and_contained () =
  with_eio_temp_dir (fun base_path ->
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "artifact-task-001.txt" in
    Fs_compat.save_file artifact_path "verified artifact\nsecond line";
    let request_id = "vrf-evidence-inspection" in
    ignore (create_evidence_request ~base_path ~request_id ~artifact_path);
    (match
       inspect_evidence
         ~base_path
         ~request_id
         ()
     with
     | VS.Evidence_available
         { items =
             VS.Evidence_artifact { content; truncated = false; _ }
             :: VS.Evidence_note "executor summary"
             :: []
         ; _
         } ->
       Alcotest.(check string)
         "completion authority reads producer artifact"
         "verified artifact\nsecond line"
         content
     | _ -> Alcotest.fail "expected completion-authority evidence projection");
    match
      VS.inspect_submitted_evidence_for_authority
        ~base_path
        ~request_id
        ~task_id:"task-001"
        ~task_worker:"keeper-executor-agent"
        ~authority:(Masc_domain.Human_operator { operator_id = "" })
    with
    | VS.Evidence_unavailable _ -> ()
    | _ -> Alcotest.fail "empty completion-authority identity must expose no evidence")

let test_submit_snapshot_resolves_docker_relative_artifact_and_explicit_note () =
  with_eio_temp_dir (fun base_path ->
    write_keeper_profile
      ~base_path
      ~keeper_name:"keeper-executor-agent"
      ~sandbox_profile:"docker";
    let artifact_dir =
      Filename.concat
        (Keeper_sandbox_config.host_root_abs_of_agent
           ~base_path
           ~agent_name:"keeper-executor-agent")
        "artifacts"
    in
    Fs_compat.mkdir_p artifact_dir;
    Fs_compat.save_file
      (Filename.concat artifact_dir "proof.txt")
      "docker-relative-proof";
    let request_id = "vrf-docker-relative-snapshot" in
    let task =
      create_protocol_evidence_request
        ~base_path
        ~request_id
        ~evidence_refs:
          [ "artifact:artifacts/proof.txt"; "note:executor summary" ]
    in
    match
      inspect_evidence
        ~task_id:task.id
        ~base_path
        ~request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact
              { reference = "artifact:artifacts/proof.txt"
              ; content = "docker-relative-proof"
              ; content_sha256
              ; _
              }
            :: VS.Evidence_note "executor summary"
            :: []
        ; _
        } ->
      Alcotest.(check string)
        "snapshot hash covers persisted bounded content"
        Digestif.SHA256.(digest_string "docker-relative-proof" |> to_hex)
        content_sha256
    | _ ->
      (match
         inspect_evidence
           ~task_id:task.id
           ~base_path
           ~request_id
           ()
       with
       | VS.Evidence_available
           { items =
               VS.Evidence_artifact_unreadable { reason; _ } :: _
           ; _
           } ->
         Alcotest.failf
           "Docker-relative artifact snapshot unreadable: %s"
           (VS.evidence_read_failure_to_string reason)
       | VS.Evidence_available { items; _ } ->
         Alcotest.failf
           "expected explicit artifact and note snapshot, got %d items"
           (List.length items)
       | VS.Evidence_unavailable { reason; _ } ->
         Alcotest.failf "persisted evidence snapshot unavailable: %s" reason))

let test_submit_snapshot_survives_mutation_deletion_and_authority_cwd () =
  with_eio_temp_dir (fun base_path ->
    write_keeper_profile
      ~base_path
      ~keeper_name:"keeper-executor-agent"
      ~sandbox_profile:"docker";
    let artifact_dir =
      Filename.concat
        (Keeper_sandbox_config.host_root_abs_of_agent
           ~base_path
           ~agent_name:"keeper-executor-agent")
        "artifacts"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "immutable.txt" in
    Fs_compat.save_file artifact_path "submit-time-content";
    let request_id = "vrf-immutable-snapshot" in
    let task =
      create_protocol_evidence_request
        ~base_path
        ~request_id
        ~evidence_refs:[ "artifact:artifacts/immutable.txt" ]
    in
    Fs_compat.save_file artifact_path "mutated-after-submit";
    Sys.remove artifact_path;
    let verifier_cwd = Filename.concat base_path "verifier-cwd" in
    Fs_compat.mkdir_p verifier_cwd;
    let original_cwd = Sys.getcwd () in
    Fun.protect
      ~finally:(fun () -> Sys.chdir original_cwd)
      (fun () ->
        Sys.chdir verifier_cwd;
        match
          inspect_evidence
            ~task_id:task.id
            ~base_path
            ~request_id
            ()
        with
        | VS.Evidence_available
            { items =
                VS.Evidence_artifact
                  { content = "submit-time-content"; _ }
                :: []
            ; _
            } ->
          ()
        | _ ->
          (match
             inspect_evidence
               ~task_id:task.id
               ~base_path
               ~request_id
               ()
           with
           | VS.Evidence_available
               { items =
                   VS.Evidence_artifact_unreadable { reason; _ } :: _
               ; _
               } ->
             Alcotest.failf
               "immutable artifact snapshot unreadable: %s"
               (VS.evidence_read_failure_to_string reason)
           | VS.Evidence_available { items; _ } ->
             Alcotest.failf
               "expected one immutable artifact snapshot, got %d items"
               (List.length items)
           | VS.Evidence_unavailable { reason; _ } ->
             Alcotest.failf "persisted evidence snapshot unavailable: %s" reason)))

let test_submit_snapshot_rejects_relative_traversal_and_symlink_escape () =
  with_eio_temp_dir (fun base_path ->
    write_keeper_profile
      ~base_path
      ~keeper_name:"keeper-executor-agent"
      ~sandbox_profile:"docker";
    let producer_root =
      Keeper_sandbox_config.host_root_abs_of_agent
        ~base_path
        ~agent_name:"keeper-executor-agent"
    in
    let artifact_dir = Filename.concat producer_root "artifacts" in
    Fs_compat.mkdir_p artifact_dir;
    let outside_path = Filename.concat base_path "outside-relative-secret.txt" in
    Fs_compat.save_file outside_path "outside";
    let symlink_path = Filename.concat artifact_dir "escape.txt" in
    Unix.symlink outside_path symlink_path;
    let request_id = "vrf-relative-boundary-snapshot" in
    let task =
      create_protocol_evidence_request
        ~base_path
        ~request_id
        ~evidence_refs:
          [ "artifact:../outside-relative-secret.txt"
          ; "artifact:artifacts/escape.txt"
          ]
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.unlink symlink_path with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () ->
        match
          inspect_evidence
            ~task_id:task.id
            ~base_path
            ~request_id
            ()
        with
        | VS.Evidence_available
            { items =
                VS.Evidence_artifact_unreadable
                  { reason = VS.Evidence_invalid_reference; _ }
                :: VS.Evidence_artifact_unreadable
                     { reason = VS.Evidence_symbolic_link; _ }
                :: []
            ; _
            } ->
          ()
        | _ ->
          Alcotest.fail
            "relative traversal and symlink escape must persist typed unreadable snapshots"))

let test_submit_snapshot_rejects_bare_and_absolute_references () =
  with_eio_temp_dir (fun base_path ->
    write_keeper_profile
      ~base_path
      ~keeper_name:"keeper-executor-agent"
      ~sandbox_profile:"docker";
    let producer_root =
      Keeper_sandbox_config.host_root_abs_of_agent
        ~base_path
        ~agent_name:"keeper-executor-agent"
    in
    Fs_compat.mkdir_p producer_root;
    let absolute_path = Filename.concat producer_root "absolute.txt" in
    Fs_compat.save_file absolute_path "must-not-be-read";
    let request_id = "vrf-explicit-reference-hard-cut" in
    let snapshot =
      VS.snapshot_submitted_evidence_json
        ~base_path
        ~worker:"keeper-executor-agent"
        [ "artifacts/bare.txt"; absolute_path ]
    in
    ignore
      (match
         V.create_request
           ~base_path
           ~request_id
           ~task_id:"task-001"
           ~output:(`Assoc [ "submitted_evidence", snapshot ])
           ~criteria:[ V.Custom "inspect explicit refs" ]
           ~worker:"keeper-executor-agent"
           ()
       with
       | Ok request -> request
       | Error detail -> Alcotest.fail detail);
    match
      inspect_evidence
        ~base_path
        ~request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact_unreadable
              { reason = VS.Evidence_invalid_reference; _ }
            :: VS.Evidence_artifact_unreadable
                 { reason = VS.Evidence_invalid_reference; _ }
            :: []
        ; _
        } ->
      ()
    | _ ->
      Alcotest.fail
        "bare and absolute references must remain typed invalid without file reads")

let test_submitted_evidence_inspection_rejects_cross_playground_path () =
  with_eio_temp_dir (fun base_path ->
    let other_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/other"
    in
    Fs_compat.mkdir_p other_dir;
    let artifact_path = Filename.concat other_dir "secret.txt" in
    Fs_compat.save_file artifact_path "must not leak";
    let request_id = "vrf-cross-playground" in
    ignore (create_evidence_request ~base_path ~request_id ~artifact_path);
    match
      inspect_evidence
        ~base_path
        ~request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact_unreadable
              { reason = VS.Evidence_invalid_reference; _ }
            :: _
        ; _
        } ->
      ()
    | _ -> Alcotest.fail "cross-playground artifact must remain unreadable")

let test_submitted_evidence_inspection_is_bounded_and_utf8_safe () =
  with_eio_temp_dir (fun base_path ->
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "large-artifact.txt" in
    let ascii_prefix = String.make 19_999 'a' in
    let full_artifact = ascii_prefix ^ "한글" ^ String.make 250_000 'z' in
    Fs_compat.save_file artifact_path full_artifact;
    let request_id = "vrf-bounded-evidence" in
    ignore (create_evidence_request ~base_path ~request_id ~artifact_path);
    match
      inspect_evidence
        ~base_path
        ~request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact
              { content; bytes; truncated = true; _ }
            :: _
        ; _
        } ->
      Alcotest.(check int) "full artifact byte count preserved"
        (String.length full_artifact) bytes;
      Alcotest.(check int) "UTF-8 boundary stays below 20KB cap" 19_999
        (String.length content);
      Alcotest.(check string) "incomplete UTF-8 codepoint removed"
        ascii_prefix content
    | _ -> Alcotest.fail "expected bounded UTF-8-safe artifact projection")

let test_submitted_evidence_rejects_malformed_utf8 () =
  with_eio_temp_dir (fun base_path ->
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "malformed.txt" in
    Fs_compat.save_file artifact_path "\xC3\x28";
    let request_id = "vrf-malformed-evidence" in
    ignore (create_evidence_request ~base_path ~request_id ~artifact_path);
    match
      inspect_evidence
        ~base_path
        ~request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact_unreadable
              { reason = VS.Evidence_invalid_utf8; _ }
            :: _
        ; _
        } ->
      ()
    | _ -> Alcotest.fail "malformed UTF-8 must remain unreadable")

let test_submitted_evidence_rejects_symlink_escape_and_fifo () =
  with_eio_temp_dir (fun base_path ->
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let outside_path = Filename.concat base_path "outside-secret.txt" in
    Fs_compat.save_file outside_path "outside-secret";
    let symlink_path = Filename.concat artifact_dir "outside-link.txt" in
    Unix.symlink outside_path symlink_path;
    let symlink_request_id = "vrf-symlink-evidence" in
    ignore
      (create_evidence_request
         ~base_path
         ~request_id:symlink_request_id
         ~artifact_path:symlink_path);
    (match
       inspect_evidence
         ~base_path
         ~request_id:symlink_request_id
         ()
     with
     | VS.Evidence_available
         { items =
             VS.Evidence_artifact_unreadable
               { reason = VS.Evidence_symbolic_link; _ }
             :: _
         ; _
         } ->
       ()
     | _ -> Alcotest.fail "symlink escape must remain unreadable");
    let fifo_path = Filename.concat artifact_dir "evidence.fifo" in
    Unix.mkfifo fifo_path 0o600;
    let fifo_request_id = "vrf-fifo-evidence" in
    ignore
      (create_evidence_request
         ~base_path
         ~request_id:fifo_request_id
         ~artifact_path:fifo_path);
    match
      inspect_evidence
        ~base_path
        ~request_id:fifo_request_id
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact_unreadable
              { reason = VS.Evidence_not_regular_file; _ }
            :: _
        ; _
        } ->
      ()
    | _ -> Alcotest.fail "FIFO evidence must remain unreadable")

let test_changed_during_read_maps_to_typed_unreadable_reason () =
  Alcotest.(check string)
    "exact-read race remains typed"
    "changed_during_read"
    (VS.evidence_read_failure_of_owned_read_failure
       (Fs_compat.Filesystem_identity_changed { path = "artifact.txt" })
     |> VS.evidence_read_failure_to_string)

let test_submitted_evidence_requires_exact_task_assignment_identity () =
  with_eio_temp_dir (fun base_path ->
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "assignment.txt" in
    Fs_compat.save_file artifact_path "assignment-secret";
    let request_id = "vrf-assignment-authority" in
    let pending =
      match
        V.create_request
          ~base_path
          ~request_id
          ~task_id:"task-001"
          ~output:
            (`Assoc
                [ ( "submitted_evidence"
                  , VS.snapshot_submitted_evidence_json
                      ~base_path
                      ~worker:"keeper-executor-agent"
                      [ "artifact:assignment.txt" ] )
                ])
          ~criteria:[ V.Custom "inspect artifact" ]
          ~worker:"keeper-executor-agent"
          ()
      with
      | Ok request -> request
      | Error detail -> Alcotest.fail detail
    in
    let check_unavailable label = function
      | VS.Evidence_unavailable _ -> ()
      | _ -> Alcotest.fail label
    in
    (match
       inspect_evidence
         ~base_path
         ~request_id:pending.id
         ()
     with
     | VS.Evidence_available _ -> ()
     | _ -> Alcotest.fail "pending evidence must be available to the completion authority");
    check_unavailable
      "task id mismatch must not expose bytes"
      (inspect_evidence
         ~task_id:"task-other"
         ~base_path
         ~request_id:pending.id
         ());
    check_unavailable
      "producer mismatch must not expose bytes"
      (inspect_evidence
         ~task_worker:"keeper-other-agent"
         ~base_path
         ~request_id:pending.id
         ()))

let test_keeper_task_projection_never_exposes_snapshot_or_verdict_action () =
  with_eio_temp_dir (fun base_path ->
    let config = W.default_config base_path in
    ignore (W.init config ~agent_name:None);
    ignore
      (W.add_task
         config
         ~title:"Produce one verifiable artifact"
         ~priority:1
         ~description:"");
    let artifact_dir =
      Filename.concat
        base_path
        ".masc/playground/docker/executor"
    in
    Fs_compat.mkdir_p artifact_dir;
    let artifact_path = Filename.concat artifact_dir "artifact-task-001.txt" in
    Fs_compat.save_file artifact_path "full-cycle-evidence";
    let request_id = "vrf-task-list-projection" in
    ignore (create_evidence_request ~base_path ~request_id ~artifact_path);
    let backlog = W.read_backlog config in
    let tasks =
      List.map
        (fun (task : Masc_domain.task) ->
           { task with
             task_status =
               Masc_domain.AwaitingVerification
                 { assignee = "keeper-executor-agent"
                 ; submitted_at = "2026-07-28T00:00:00Z"
                 ; verification_id = request_id
                 }
           })
        backlog.tasks
    in
    W.write_backlog
      config
      { backlog with tasks; version = backlog.version + 1 };
    let projection = W.list_tasks config in
    Alcotest.(check bool)
      "row identifies the completion-authority wait"
      true
      (contains_substring projection
         "awaiting_completion_authority task_id=task-001");
    Alcotest.(check bool)
      "keeper row does not choose a verdict action"
      false
      (contains_substring projection "ACTION:");
    (match
       W.claim_task_r config ~agent_name:"keeper-executor-agent" ~task_id:"task-001" ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "producer must not claim its pending obligation");
    (match
       W.claim_task_r config ~agent_name:"keeper-verifier-agent" ~task_id:"task-001" ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "no Keeper may claim a pending obligation");
    (match
       W.claim_task_r config ~agent_name:"keeper-sangsu-agent" ~task_id:"task-001" ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "another Keeper claimed the pending obligation");
    Alcotest.(check bool)
      "task projection contains no evidence bytes"
      false
      (contains_substring projection "full-cycle-evidence");
    Alcotest.(check bool)
      "task projection keeps request metadata"
      true
      (contains_substring projection request_id);
    Alcotest.(check bool)
      "task projection has no assigned verifier"
      false
      (contains_substring projection "assigned_verifier=");
    Alcotest.(check bool)
      "task projection has no verdict action"
      false
      (contains_substring projection "ACTION:"))

(* --- ID generation property test (#7544) --- *)

module StringSet = Set.Make (String)

let test_generate_id_prefix () =
  let id = V.generate_id () in
  Alcotest.(check bool) "vrf- prefix" true
    (String.length id > 4 && String.sub id 0 4 = "vrf-")

let test_generate_id_no_collisions () =
  (* 10000 consecutive ids must be unique — the old Hashtbl.hash-based
     generator collided within the same millisecond. *)
  let n = 10_000 in
  let seen = ref StringSet.empty in
  for _ = 1 to n do
    let id = V.generate_id () in
    seen := StringSet.add id !seen
  done;
  Alcotest.(check int) "all 10k ids unique" n (StringSet.cardinal !seen)

let () =
  Alcotest.run "Verification" [
    "criterion", [
      Alcotest.test_case "roundtrip" `Quick test_criterion_roundtrip;
      Alcotest.test_case "of_yojson errors" `Quick test_criterion_of_yojson_errors;
    ];
    "id_generation", [
      Alcotest.test_case "vrf- prefix" `Quick test_generate_id_prefix;
      Alcotest.test_case "10k ids collision-free" `Quick test_generate_id_no_collisions;
    ];
    "storage", [
      Alcotest.test_case "create and load" `Quick test_create_and_load;
      Alcotest.test_case "delete request (idempotent)" `Quick test_delete_request;
      Alcotest.test_case "list requests" `Quick test_list_requests;
      Alcotest.test_case "list requests missing dir stays quiet" `Quick
        test_list_requests_missing_dir_stays_quiet;
      Alcotest.test_case "verifications dir resolves active store" `Quick
        test_verifications_dir_resolves_active_store;
      Alcotest.test_case "request path ignores legacy root store" `Quick
        test_request_path_ignores_legacy_root_store;
      Alcotest.test_case "list requests skips bad entries with metric" `Quick
        test_list_requests_skips_bad_entries_with_metric;
      Alcotest.test_case "list requests ignores legacy-only stale entries" `Quick
        test_list_requests_ignores_legacy_only_stale_entries;
      Alcotest.test_case "list requests ignores legacy root entries" `Quick
        test_list_requests_ignores_legacy_root_entries;
      Alcotest.test_case "submitted evidence authority-scoped and contained" `Quick
        test_submitted_evidence_inspection_is_authority_scoped_and_contained;
      Alcotest.test_case "submit snapshot resolves Docker relative refs" `Quick
        test_submit_snapshot_resolves_docker_relative_artifact_and_explicit_note;
      Alcotest.test_case "submit snapshot is immutable and cwd-independent" `Quick
        test_submit_snapshot_survives_mutation_deletion_and_authority_cwd;
      Alcotest.test_case "submit snapshot rejects traversal and symlink escape" `Quick
        test_submit_snapshot_rejects_relative_traversal_and_symlink_escape;
      Alcotest.test_case "submit snapshot rejects bare and absolute refs" `Quick
        test_submit_snapshot_rejects_bare_and_absolute_references;
      Alcotest.test_case "submitted evidence rejects cross playground" `Quick
        test_submitted_evidence_inspection_rejects_cross_playground_path;
      Alcotest.test_case "submitted evidence bounded UTF-8" `Quick
        test_submitted_evidence_inspection_is_bounded_and_utf8_safe;
      Alcotest.test_case "submitted evidence rejects malformed UTF-8" `Quick
        test_submitted_evidence_rejects_malformed_utf8;
      Alcotest.test_case "submitted evidence rejects symlink and FIFO" `Quick
        test_submitted_evidence_rejects_symlink_escape_and_fifo;
      Alcotest.test_case "submitted evidence race remains typed" `Quick
        test_changed_during_read_maps_to_typed_unreadable_reason;
      Alcotest.test_case "submitted evidence requires exact assignment identity" `Quick
        test_submitted_evidence_requires_exact_task_assignment_identity;
      Alcotest.test_case "keeper task projection has no evidence or verdict action" `Quick
        test_keeper_task_projection_never_exposes_snapshot_or_verdict_action;
    ];
  ]
