(** Tests for Verification module *)

(* Mirage_crypto_rng is consumed by V.generate_id (#7544). *)
let () = Mirage_crypto_rng_unix.use_default ()

module V = Masc.Verification
module P = Masc.Otel_metric_store
module VS = Workspace_verification_store
module CU = Workspace_utils
module W = Workspace_core
module VP = Masc.Verification_protocol

let submit_verdict_via_protocol ~base_path ~req_id ~verifier ~verdict =
  match V.load_request base_path req_id with
  | Error _ as error -> error
  | Ok request ->
    let config = W.default_config base_path in
    let recorded =
      match verdict with
      | V.Pass ->
        VP.record_approve_verification
          ~config
          ~task_id:request.task_id
          ~verifier
          ~verification_id:req_id
          ~notes:"verified"
      | V.Fail reason ->
        VP.record_reject_verification
          ~config
          ~task_id:request.task_id
          ~verifier
          ~verification_id:req_id
          ~reason
      | V.Partial _ ->
        Error "Partial verdict is not a Task verification protocol outcome"
    in
    (match recorded with
     | Error _ as error -> error
     | Ok () -> V.load_request base_path req_id)

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

(* --- Verdict tests --- *)

let test_verdict_roundtrip () =
  let verdicts = [V.Pass; V.Fail "bad output"; V.Partial (0.75, "mostly ok")] in
  List.iter (fun v ->
    let json = V.verdict_to_yojson v in
    match V.verdict_of_yojson json with
    | Ok result ->
        Alcotest.(check bool) "verdict roundtrip" true
          (V.equal_verdict v result)
    | Error e -> Alcotest.fail e
  ) verdicts

(* --- Evaluation tests --- *)

let test_evaluate_contains () =
  let output = `String "hello world" in
  Alcotest.(check bool) "contains match" true
    (V.evaluate_criterion output (V.Contains "hello") = V.Pass);
  Alcotest.(check bool) "contains no match" true
    (match V.evaluate_criterion output (V.Contains "xyz") with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_not_contains () =
  let output = `String "hello world" in
  Alcotest.(check bool) "not_contains pass" true
    (V.evaluate_criterion output (V.Not_contains "xyz") = V.Pass);
  Alcotest.(check bool) "not_contains fail" true
    (match V.evaluate_criterion output (V.Not_contains "hello") with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_literal_and_empty_needles () =
  let output = `String "literal .* needle" in
  Alcotest.(check bool) "contains treats regex metacharacters literally" true
    (V.evaluate_criterion output (V.Contains ".*") = V.Pass);
  Alcotest.(check bool) "contains empty needle stays fail" true
    (match V.evaluate_criterion output (V.Contains "") with
     | V.Fail _ -> true | _ -> false);
  Alcotest.(check bool) "not_contains empty needle stays pass" true
    (V.evaluate_criterion output (V.Not_contains "") = V.Pass)

let test_evaluate_schema_match () =
  let output = `Assoc [("key", `String "value")] in
  Alcotest.(check bool) "schema non-null pass" true
    (V.evaluate_criterion output (V.Schema_match (`Assoc [])) = V.Pass);
  Alcotest.(check bool) "schema null fail" true
    (match V.evaluate_criterion `Null (V.Schema_match (`Assoc [])) with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_custom () =
  let output = `String "test" in
  Alcotest.(check bool) "custom returns partial" true
    (match V.evaluate_criterion output (V.Custom "check quality") with
     | V.Partial _ -> true | _ -> false)

let test_evaluate_all_pass () =
  let output = `String "hello world foo" in
  let criteria = [V.Contains "hello"; V.Not_contains "error"] in
  Alcotest.(check bool) "all pass" true
    (V.evaluate_all output criteria = V.Pass)

let test_evaluate_all_fail () =
  let output = `String "hello world" in
  let criteria = [V.Contains "hello"; V.Contains "missing"] in
  Alcotest.(check bool) "one fail = overall fail" true
    (match V.evaluate_all output criteria with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_empty_criteria () =
  Alcotest.(check bool) "empty criteria = pass" true
    (V.evaluate_all `Null [] = V.Pass)

(* --- Cross-agent enforcement --- *)

let test_cross_agent_same () =
  match V.validate_cross_agent ~worker:"claude" ~verifier:"claude" with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "same agent should be rejected"

let test_cross_agent_different () =
  match V.validate_cross_agent ~worker:"claude" ~verifier:"codex" with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

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
  let submitted_evidence = [ artifact_path; "executor summary" ] in
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
            [ ( "submitted_evidence"
              , `List (List.map (fun value -> `String value) submitted_evidence) )
            ; "submitted_evidence_snapshot", evidence_snapshot
            ])
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
    ~task_verifier ~viewer () =
  VS.inspect_submitted_evidence
    ~base_path
    ~request_id
    ~task_id
    ~task_worker
    ~task_verifier
    ~viewer

let test_submitted_evidence_inspection_is_assigned_and_contained () =
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
         ~task_verifier:(Some "keeper-verifier-agent")
         ~viewer:"keeper-verifier-agent"
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
         "assigned verifier reads producer artifact"
         "verified artifact\nsecond line"
         content
     | _ -> Alcotest.fail "expected assigned verifier evidence projection");
    match
      inspect_evidence
        ~base_path
        ~request_id
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-sangsu-agent"
        ()
    with
    | VS.Evidence_metadata_only _ -> ()
    | _ -> Alcotest.fail "non-assigned keeper must receive metadata only")

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
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-verifier-agent"
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact
              { reference = "artifact:artifacts/proof.txt"
              ; content = "docker-relative-proof"
              ; sha256
              ; _
              }
            :: VS.Evidence_note "executor summary"
            :: []
        ; _
        } ->
      Alcotest.(check string)
        "snapshot hash covers persisted bounded content"
        Digestif.SHA256.(digest_string "docker-relative-proof" |> to_hex)
        sha256
    | _ ->
      (match
         inspect_evidence
           ~task_id:task.id
           ~base_path
           ~request_id
           ~task_verifier:(Some "keeper-verifier-agent")
           ~viewer:"keeper-verifier-agent"
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
       | VS.Evidence_metadata_only _ ->
         Alcotest.fail "assigned verifier unexpectedly received metadata only"
       | VS.Evidence_unavailable { reason; _ } ->
         Alcotest.failf "persisted evidence snapshot unavailable: %s" reason))

let test_submit_snapshot_survives_mutation_deletion_and_verifier_cwd () =
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
            ~task_verifier:(Some "keeper-verifier-agent")
            ~viewer:"keeper-verifier-agent"
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
               ~task_verifier:(Some "keeper-verifier-agent")
               ~viewer:"keeper-verifier-agent"
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
           | VS.Evidence_metadata_only _ ->
             Alcotest.fail "assigned verifier unexpectedly received metadata only"
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
            ~task_verifier:(Some "keeper-verifier-agent")
            ~viewer:"keeper-verifier-agent"
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
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-verifier-agent"
        ()
    with
    | VS.Evidence_available
        { items =
            VS.Evidence_artifact_unreadable
              { reason = VS.Evidence_outside_worker_playground; _ }
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
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-verifier-agent"
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
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-verifier-agent"
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
         ~task_verifier:(Some "keeper-verifier-agent")
         ~viewer:"keeper-verifier-agent"
         ()
     with
     | VS.Evidence_available
         { items =
             VS.Evidence_artifact_unreadable
               { reason = VS.Evidence_outside_worker_playground; _ }
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
        ~task_verifier:(Some "keeper-verifier-agent")
        ~viewer:"keeper-verifier-agent"
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
                  , `List [ `String artifact_path ] )
                ; ( "submitted_evidence_snapshot"
                  , VS.snapshot_submitted_evidence_json
                      ~base_path
                      ~worker:"keeper-executor-agent"
                      [ artifact_path ] )
                ])
          ~criteria:[ V.Custom "inspect artifact" ]
          ~worker:"keeper-executor-agent"
          ()
      with
      | Ok request -> request
      | Error detail -> Alcotest.fail detail
    in
    let check_metadata_only label = function
      | VS.Evidence_metadata_only _ -> ()
      | _ -> Alcotest.fail label
    in
    (match
       inspect_evidence
         ~base_path
         ~request_id:pending.id
         ~task_verifier:(Some "keeper-verifier-agent")
         ~viewer:"keeper-verifier-agent"
         ()
     with
     | VS.Evidence_available _ -> ()
     | _ -> Alcotest.fail "Pending evidence must be available to the Task phase winner");
    check_metadata_only
      "task id mismatch must not expose bytes"
      (inspect_evidence
         ~task_id:"task-other"
         ~base_path
         ~request_id:pending.id
         ~task_verifier:(Some "keeper-verifier-agent")
         ~viewer:"keeper-verifier-agent"
         ());
    check_metadata_only
      "producer mismatch must not expose bytes"
      (inspect_evidence
         ~task_worker:"keeper-other-agent"
         ~base_path
         ~request_id:pending.id
         ~task_verifier:(Some "keeper-verifier-agent")
         ~viewer:"keeper-verifier-agent"
         ());
    check_metadata_only
      "task phase verifier mismatch must not expose bytes"
      (inspect_evidence
         ~base_path
         ~request_id:pending.id
         ~task_verifier:(Some "keeper-sangsu-agent")
         ~viewer:"keeper-verifier-agent"
         ());
    check_metadata_only
      "unassigned task phase must not expose bytes"
      (inspect_evidence
         ~base_path
         ~request_id:pending.id
         ~task_verifier:None
         ~viewer:"keeper-verifier-agent"
         ()))

let test_keeper_task_projection_exposes_snapshot_only_to_assigned_verifier () =
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
                 ; phase = Masc_domain.Awaiting_verifier
                 }
           })
        backlog.tasks
    in
    W.write_backlog
      config
      { backlog with tasks; version = backlog.version + 1 };
    let unassigned =
      W.list_tasks config ~verification_viewer:"keeper-verifier-agent"
    in
    Alcotest.(check bool)
      "unassigned row prescribes claim"
      true
      (contains_substring unassigned
         "ACTION: keeper_task_claim task_id=task-001");
    Alcotest.(check bool)
      "unassigned row forbids producer-path read"
      true
      (contains_substring unassigned "do not Read producer paths");
    (match
       W.claim_task_r config ~agent_name:"keeper-executor-agent" ~task_id:"task-001" ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "producer must not claim its own verification");
    (match
       W.claim_task_r config ~agent_name:"keeper-verifier-agent" ~task_id:"task-001" ()
     with
     | Ok message ->
       Alcotest.(check bool)
         "claim response carries persisted snapshot"
         true
         (contains_substring message "full-cycle-evidence")
     | Error err ->
       Alcotest.fail
         ("verifier claim failed: " ^ Masc_domain.masc_error_to_string err));
    (match
       W.claim_task_r config ~agent_name:"keeper-sangsu-agent" ~task_id:"task-001" ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "second verifier stole the assignment");
    let request =
      match V.load_request base_path request_id with
      | Ok request -> request
      | Error detail -> Alcotest.fail detail
    in
    Alcotest.(check bool)
      "request remains pending after Task-phase claim"
      true
      (match request.status with V.Pending -> true | V.Completed _ -> false);
    let assigned =
      W.list_tasks
        config
        ~verification_viewer:"keeper-verifier-agent"
    in
    Alcotest.(check bool)
      "assigned verifier receives content"
      true
      (contains_substring assigned "full-cycle-evidence");
    let other =
      W.list_tasks
        config
        ~verification_viewer:"keeper-sangsu-agent"
    in
    Alcotest.(check bool)
      "other keeper receives no content"
      false
      (contains_substring other "full-cycle-evidence");
    Alcotest.(check bool)
      "other keeper keeps request metadata"
      true
      (contains_substring other request_id);
    Alcotest.(check bool)
      "other keeper is told to skip"
      true
      (contains_substring other "ACTION: skip");
    let external_projection = W.list_tasks config in
    Alcotest.(check bool)
      "external task list receives no content"
      false
      (contains_substring external_projection "full-cycle-evidence"))

let test_submit_verdict () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "good") ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match submit_verdict_via_protocol ~base_path ~req_id:req.id ~verifier:"codex"
            ~verdict:V.Pass with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check bool) "completed" true
              (match updated.status with V.Completed V.Pass -> true | _ -> false);
            (* verifier must be persisted so the dashboard projection never
               emits "approved with null approved_by" for completed rows. *)
            Alcotest.(check (option string)) "verifier recorded"
              (Some "codex") updated.verifier)

let test_submit_verdict_persists_verifier () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "good") ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        Alcotest.(check (option string)) "starts unassigned" None req.verifier;
        match submit_verdict_via_protocol ~base_path ~req_id:req.id
            ~verifier:"operator:dashboard" ~verdict:V.Pass with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check (option string)) "verifier persisted"
              (Some "operator:dashboard") updated.verifier)

let test_submit_verdict_cannot_overwrite_terminal_receipt () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "good") ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
      (match
         submit_verdict_via_protocol ~base_path ~req_id:req.id ~verifier:"codex"
           ~verdict:V.Pass
       with
       | Error e -> Alcotest.fail e
       | Ok _ -> ());
      (match
         submit_verdict_via_protocol ~base_path ~req_id:req.id ~verifier:"gemini"
           ~verdict:(V.Fail "overwrite")
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "terminal verification receipt was overwritten");
      match V.load_request base_path req.id with
      | Error e -> Alcotest.fail e
      | Ok final ->
        Alcotest.(check bool)
          "first terminal verdict survives"
          true
          (match final.status, final.verifier with
           | V.Completed V.Pass, Some "codex" -> true
           | _ -> false))

let test_concurrent_verdict_is_first_writer_wins () =
  with_eio_temp_dir (fun base_path ->
    let req =
      match
        V.create_request
          ~base_path
          ~task_id:"task-concurrent-verdict"
          ~output:`Null
          ~criteria:[]
          ~worker:"worker"
          ()
      with
      | Ok req -> req
      | Error detail -> Alcotest.fail detail
    in
    let left = ref None in
    let right = ref None in
    Eio.Fiber.both
      (fun () ->
         left :=
           Some
             (V.Internal.submit_verdict
                ~base_path
                ~req_id:req.id
                ~verifier:"verifier-a"
                ~verdict:V.Pass))
      (fun () ->
         right :=
           Some
             (V.Internal.submit_verdict
                ~base_path
                ~req_id:req.id
                ~verifier:"verifier-b"
                ~verdict:(V.Fail "rejected")));
    match !left, !right with
    | Some (Ok _), Some (Error _) | Some (Error _), Some (Ok _) -> ()
    | Some (Ok _), Some (Ok _) ->
      Alcotest.fail "concurrent verdicts both overwrote the receipt"
    | Some (Error left), Some (Error right) ->
      Alcotest.failf "both concurrent verdicts failed: %s / %s" left right
    | None, _ | _, None -> Alcotest.fail "concurrent verdict fiber did not return")

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

(* --- Attribution conversion tests --- *)

module A = Attribution

let test_origin_det_for_rule_based () =
  let cs = [ V.Contains "x"; V.Not_contains "y"; V.Schema_match (`Assoc []) ] in
  Alcotest.(check bool) "Det" true (V.origin_of_criteria cs = A.Det)

let test_origin_nondet_for_custom () =
  let cs = [ V.Contains "x"; V.Custom "is it good?" ] in
  Alcotest.(check bool) "NonDet" true (V.origin_of_criteria cs = A.NonDet)

let test_verdict_pass_to_attribution () =
  let attr = V.to_attribution ~origin:Det ~evidence:`Null V.Pass in
  Alcotest.(check string) "gate" "verification" attr.gate;
  Alcotest.(check bool) "outcome=Passed" true
    (match attr.outcome with A.Passed -> true | _ -> false)

let test_verdict_fail_to_attribution () =
  let attr =
    V.to_attribution ~origin:Det ~evidence:`Null
      (V.Fail "output does not match schema")
  in
  match attr.outcome with
  | A.Policy_failed { reason } ->
    Alcotest.(check string) "reason" "output does not match schema" reason
  | _ -> Alcotest.fail "expected Policy_failed"

let test_verdict_partial_to_attribution () =
  let attr =
    V.to_attribution ~origin:NonDet ~evidence:`Null
      (V.Partial (0.75, "partial match"))
  in
  match attr.outcome with
  | A.Partial_pass { score; rationale } ->
    Alcotest.(check (float 0.0001)) "score" 0.75 score;
    Alcotest.(check string) "rationale" "partial match" rationale
  | _ -> Alcotest.fail "expected Partial_pass"

let test_attribution_of_request_none_for_pending () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1" ~output:`Null
            ~criteria:[ V.Contains "x" ] ~worker:"w" () with
    | Error e -> Alcotest.fail ("create failed: " ^ e)
    | Ok req ->
      Alcotest.(check bool) "None for Pending" true
        (V.attribution_of_request req = None))

let test_attribution_of_request_derives_origin () =
  with_temp_dir (fun base_path ->
    (* Build a request with a Custom criterion and a Completed Pass verdict. *)
    match V.create_request ~base_path ~task_id:"t2" ~output:`Null
            ~criteria:[ V.Contains "hello"; V.Custom "must be kind" ]
            ~worker:"claude" () with
    | Error e -> Alcotest.fail ("create failed: " ^ e)
    | Ok req ->
      let completed = { req with status = V.Completed V.Pass } in
      match V.attribution_of_request completed with
      | Some attr ->
        Alcotest.(check bool) "origin=NonDet (Custom present)" true
          (attr.A.origin = A.NonDet)
      | None -> Alcotest.fail "expected Some attribution")

let () =
  Alcotest.run "Verification" [
    "criterion", [
      Alcotest.test_case "roundtrip" `Quick test_criterion_roundtrip;
      Alcotest.test_case "of_yojson errors" `Quick test_criterion_of_yojson_errors;
    ];
    "verdict", [
      Alcotest.test_case "roundtrip" `Quick test_verdict_roundtrip;
    ];
    "evaluation", [
      Alcotest.test_case "contains" `Quick test_evaluate_contains;
      Alcotest.test_case "not_contains" `Quick test_evaluate_not_contains;
      Alcotest.test_case "literal and empty needles" `Quick
        test_evaluate_literal_and_empty_needles;
      Alcotest.test_case "schema_match" `Quick test_evaluate_schema_match;
      Alcotest.test_case "custom" `Quick test_evaluate_custom;
      Alcotest.test_case "all pass" `Quick test_evaluate_all_pass;
      Alcotest.test_case "all fail" `Quick test_evaluate_all_fail;
      Alcotest.test_case "empty criteria" `Quick test_evaluate_empty_criteria;
    ];
    "cross_agent", [
      Alcotest.test_case "same agent rejected" `Quick test_cross_agent_same;
      Alcotest.test_case "different agents ok" `Quick test_cross_agent_different;
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
      Alcotest.test_case "submitted evidence assigned and contained" `Quick
        test_submitted_evidence_inspection_is_assigned_and_contained;
      Alcotest.test_case "submit snapshot resolves Docker relative refs" `Quick
        test_submit_snapshot_resolves_docker_relative_artifact_and_explicit_note;
      Alcotest.test_case "submit snapshot is immutable and cwd-independent" `Quick
        test_submit_snapshot_survives_mutation_deletion_and_verifier_cwd;
      Alcotest.test_case "submit snapshot rejects traversal and symlink escape" `Quick
        test_submit_snapshot_rejects_relative_traversal_and_symlink_escape;
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
      Alcotest.test_case "keeper task projection assigned verifier only" `Quick
        test_keeper_task_projection_exposes_snapshot_only_to_assigned_verifier;
      Alcotest.test_case "submit verdict" `Quick test_submit_verdict;
      Alcotest.test_case "submit verdict persists verifier" `Quick
        test_submit_verdict_persists_verifier;
      Alcotest.test_case "submit verdict terminal non-overwrite" `Quick
        test_submit_verdict_cannot_overwrite_terminal_receipt;
      Alcotest.test_case "concurrent verdict is first-writer-wins" `Quick
        test_concurrent_verdict_is_first_writer_wins;
    ];
    "attribution", [
      Alcotest.test_case "origin=Det for rule-based criteria" `Quick
        test_origin_det_for_rule_based;
      Alcotest.test_case "origin=NonDet when Custom present" `Quick
        test_origin_nondet_for_custom;
      Alcotest.test_case "Pass → Attribution.Passed" `Quick
        test_verdict_pass_to_attribution;
      Alcotest.test_case "Fail → Attribution.Policy_failed" `Quick
        test_verdict_fail_to_attribution;
      Alcotest.test_case "Partial → Attribution.Partial_pass" `Quick
        test_verdict_partial_to_attribution;
      Alcotest.test_case "attribution_of_request None for Pending" `Quick
        test_attribution_of_request_none_for_pending;
      Alcotest.test_case "attribution_of_request derives origin" `Quick
        test_attribution_of_request_derives_origin;
    ];
  ]
