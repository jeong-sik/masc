(** The export half of [keeper_artifact_transfer].

    A Keeper names the path, so the Keeper chooses the size, and the bytes land
    in the blob store for good. This suite pins the ceiling that stands between
    those two facts. *)

module Workspace = Masc.Workspace
module Keeper_peer_artifact = Masc.Keeper_peer_artifact
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_tool_execution = Masc.Keeper_tool_execution

let temp_dir () =
  let path = Filename.temp_file "keeper_peer_artifact_" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error _ -> ()
;;

let rec ensure_dir path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) @@ fun () ->
  output_string channel contents
;;

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv key value
      | None -> Unix.putenv key "")
    f
;;

(* The export runs a command in the Keeper's sandbox. With no turn factory that
   is the Docker fallback, so a fake [docker] on PATH is what stands in for the
   container -- the same stand-in the sandbox read backend's own suite uses. It
   answers [run] with as many bytes as the test asked for, regardless of the
   argv, so the size the handler sees is the test's choice. *)
let with_fake_docker_emitting ~bytes f =
  let dir = temp_dir () in
  let docker = Filename.concat dir "docker" in
  write_file
    docker
    (Printf.sprintf
       "#!/bin/sh\n\
        case \"$1\" in\n\
        \  info) printf '[]\\n'; exit 0;;\n\
        \  image) printf '[]\\n'; exit 0;;\n\
        \  run) printf '%%*s' %d '' | tr ' ' 'x'; exit 0;;\n\
        \  *) exit 2;;\n\
        esac\n"
       bytes);
  Unix.chmod docker 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | Some _ | None -> dir
  in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker @@ fun () -> with_env "PATH" path f
;;

let export_request path =
  `Assoc
    [ "action", `String "export"; "path", `String path; "purpose", `String "handoff" ]
;;

let never_writes _ = Alcotest.fail "export must not write into the peer's tree"

let run_export ~base ~emitting =
  let config = Workspace.default_config base in
  Masc_test_deps.write_sandbox_image_catalog ~base_path:base [ "base", "alpine:test" ];
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "peer-exporter" ]) with
    | Ok meta ->
      { meta with
        Masc.Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Docker
      ; sandbox_image = Some "base"
      }
    | Error detail -> Alcotest.fail detail
  in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir (Filename.concat host_root "scratch");
  write_file (Filename.concat host_root "scratch/artifact.bin") (String.make emitting 'x');
  with_fake_docker_emitting ~bytes:emitting @@ fun () ->
  Keeper_peer_artifact.handle
    ~config
    ~meta
    ~turn_sandbox_factory:None
    ~write:never_writes
    ~args:(export_request "scratch/artifact.bin")
;;

(* One byte past the ceiling is what the read asks for, and it is the only way
   to tell a file that fits from one that was cut. Cutting instead of refusing
   would be worse than it looks: the reference records the cut length, so
   [fetch]'s "size differs from its reference" check would pass and the peer
   would receive a truncated artifact as a whole one. *)
let test_an_oversize_export_is_refused_rather_than_shortened () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  with_env "MASC_KEEPER_PEER_ARTIFACT_MAX_BYTES" "64" @@ fun () ->
  let execution = run_export ~base ~emitting:65 in
  (match execution.Keeper_tool_execution.disposition with
   | Tool_result.Failed Tool_result.Policy_rejection -> ()
   | Tool_result.Failed _ ->
     Alcotest.failf "an oversize export is a policy refusal, not a runtime failure: %s"
       execution.Keeper_tool_execution.raw_output
   | Tool_result.Completed _ | Tool_result.Deferred _ ->
     Alcotest.fail "an oversize export was accepted");
  let said = execution.Keeper_tool_execution.raw_output in
  Alcotest.(check bool)
    "the refusal names the ceiling it enforced"
    true
    (String_util.contains_substring said "64");
  Alcotest.(check bool)
    "and says the file was too big rather than that it was cut"
    true
    (String_util.contains_substring said "larger than")
;;

(* The export reads through the capture path, which needs an authoritative
   pipe EOF; without an Eio runtime it degrades to the Unix fallback and every
   read fails before the ceiling is ever consulted. So the suite boots one,
   the way the sandbox read backend's own suite does. *)
(* A blocked store root must return the canonical store failure through the
   export's typed Runtime_failure result. Compare the public producer and
   consumer directly: parent validation may reject the path before mkdir. *)
let test_an_unwritable_store_root_fails_the_export_not_the_dispatch () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  let masc_dir = Filename.concat base ".masc" in
  ensure_dir masc_dir;
  let blocked_root = Filename.concat masc_dir "tool_blobs" in
  write_file blocked_root "not a directory";
  let bytes = String.make 8 'x' in
  let store_failure =
    match Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:base)
            ~bytes ~mime:"application/octet-stream" with
    | _reference -> Alcotest.fail "a blocked store root accepted a durable put"
    | exception Sys_error detail -> detail
  in
  let execution = run_export ~base ~emitting:(String.length bytes) in
  (match execution.Keeper_tool_execution.disposition with
   | Tool_result.Failed Tool_result.Runtime_failure -> ()
   | Tool_result.Failed _ ->
     Alcotest.failf "a failed store put is a runtime failure, not: %s"
       execution.Keeper_tool_execution.raw_output
   | Tool_result.Completed _ | Tool_result.Deferred _ ->
     Alcotest.fail "an export whose store root is not a directory was accepted");
  let said = execution.Keeper_tool_execution.raw_output in
  Alcotest.(check bool)
    "the failure names the store path it could not create"
    true
    (String_util.contains_substring said "tool_blobs");
  Alcotest.(check string)
    "export preserves the exact canonical store failure"
    store_failure
    said;
  Alcotest.(check string)
    "failed storage preserves the blocked root bytes"
    "not a directory"
    (In_channel.with_open_bin blocked_root In_channel.input_all)
;;

let with_materialization f =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  let expected = "binary\000\255payload" in
  let blob = Tool_blob_store.put_durable
      (Tool_blob_store.create ~base_path:base) ~bytes:expected ~mime:"application/octet-stream" in
  let artifact = match Masc.Keeper_peer_artifact_ref.make ~blob ~filename:"proof.bin" ~purpose:"handoff" with
    | Ok reference -> reference | Error detail -> Alcotest.fail detail in
  let state = ref (Error (Masc.Keeper_sandbox_read_backend.Missing_file "absent")) in
  let reads = ref 0 and writes = ref 0 in
  let read ~max_bytes =
    incr reads;
    Alcotest.(check int) "observe one byte beyond expected size" (String.length expected + 1) max_bytes;
    Result.map (fun bytes -> String.sub bytes 0 (min (String.length bytes) max_bytes)) !state in
  let invoke write = Keeper_peer_artifact.materialize ~base_path:base ~artifact ~path:"proof.bin"
      ~fetch:(fun () -> Ok expected) ~read ~write:(fun () -> incr writes; write ()) in
  f ~base_path:base ~expected ~state ~reads ~writes ~invoke
;;

(* Follow the actual Tool_bridge consumer, then fetch the model's manifest
   marker. A disposition-only check misses a completed producer whose output
   is rejected at this boundary. *)
let project_execution ~base_path execution =
  let data = match execution.Keeper_tool_execution.data with
    | Some data -> data | None -> Alcotest.fail "expected typed artifact result" in
  let result = match execution.disposition with
    | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:"keeper_artifact_transfer"
        ~start_time:(Tool_timing.start ()) ~data ?metadata:execution.metadata ()
    | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:"keeper_artifact_transfer"
        ~start_time:(Tool_timing.start ()) ~class_ ~data ?metadata:execution.metadata
        ~effect_disposition:execution.failure_effect_disposition execution.raw_output
    | Tool_result.Deferred () -> Alcotest.fail "expected settled artifact result" in
  Masc.Tool_bridge.to_agent_core_typed_result ~base_path result
;;

let check_projected_manifest ~base_path execution =
  let data = Option.get execution.Keeper_tool_execution.data in
  let content = match project_execution ~base_path execution with
    | Ok output -> output.Agent_core.Types.content
    | Error error -> error.Agent_core.Types.message in
  let manifest = match Tool_output.decode_from_agent_core content with
    | Tool_output.Decoded reference -> reference
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
      Alcotest.failf "model did not receive a manifest: %s" content in
  let bytes = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:manifest.sha256 with
    | Ok (Some bytes) -> bytes | Ok None -> Alcotest.fail "manifest is not durable"
    | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error) in
  match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string bytes) with
  | Tool_output.Decoded_artifact_manifest { content; structured_content } ->
    Alcotest.(check string) "manifest carries this exact producer message" execution.raw_output content;
    Alcotest.(check bool) "model manifest binds this exact result" true
      (Yojson.Safe.equal data structured_content)
  | Tool_output.Not_artifact_manifest -> Alcotest.fail "not a result manifest"
  | Tool_output.Invalid_artifact_manifest { detail } -> Alcotest.fail detail
;;

let completed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ -> Alcotest.fail result.raw_output
;;

let test_materialize_verifies_recipient_and_repeat_does_not_write () =
  with_materialization @@ fun ~base_path ~expected ~state ~reads:_ ~writes ~invoke ->
  let write () = state := Ok expected; Keeper_tool_execution.success_data (`Assoc ["ok", `Bool true]) in
  completed (invoke write);
  let repeated = invoke write in
  completed repeated;
  check_projected_manifest ~base_path repeated;
  Alcotest.(check int) "one write, verified repeat only reads" 1 !writes
;;

let test_materialize_does_not_accept_a_matching_prefix () =
  with_materialization @@ fun ~base_path:_ ~expected ~state ~reads:_ ~writes ~invoke ->
  state := Ok (expected ^ "extra");
  completed (invoke (fun () -> state := Ok expected; Keeper_tool_execution.success "written"));
  Alcotest.(check int) "longer target must be replaced" 1 !writes
;;

let test_materialize_recovers_lost_write_response_without_replay () =
  with_materialization @@ fun ~base_path ~expected ~state ~reads ~writes ~invoke ->
  let result = invoke (fun () ->
    state := Ok expected;
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure "response lost") in
  completed result;
  check_projected_manifest ~base_path result;
  Alcotest.(check int) "uncertain write is never replayed" 1 !writes;
  Alcotest.(check int) "read reconciles the uncertain result" 2 !reads;
  Alcotest.(check bool) "completion is verified" true
    Yojson.Safe.Util.(member "verified" (Option.get result.data) |> to_bool);
  Alcotest.(check bool) "recovery is explicit" true
    Yojson.Safe.Util.(member "recovered" (Option.get result.data) |> to_bool)
;;

let test_materialize_does_not_trust_success_without_bytes () =
  with_materialization @@ fun ~base_path ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  let result = invoke (fun () -> state := Ok "partial"; Keeper_tool_execution.success "written") in
  Alcotest.(check bool) "mismatching write is not completion" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "write effect remains recorded" true
    (result.failure_effect_disposition = Tool_result.Proven_post_effect);
  check_projected_manifest ~base_path result;
  Alcotest.(check int) "no blind corrective write" 1 !writes
;;

let test_materialize_preserves_gate_deferral () =
  with_materialization @@ fun ~base_path:_ ~expected ~state ~reads ~writes:_ ~invoke ->
  let deferred = Keeper_tool_execution.deferred_external_effect_data ~approval_id:"exact-approval" (`Assoc []) in
  let result = invoke (fun () -> state := Ok expected; deferred) in
  Alcotest.(check bool) "Gate receipt is unchanged" true (result == deferred);
  Alcotest.(check int) "no post-read turns a Gate decision into success" 1 !reads
;;

let test_materialize_preserves_pre_effect_failure () =
  with_materialization @@ fun ~base_path:_ ~expected ~state ~reads ~writes:_ ~invoke ->
  let refused = Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect "writer refused before mutation" in
  let result = invoke (fun () -> state := Ok expected; refused) in
  Alcotest.(check bool) "producer phase remains authoritative" true (result == refused);
  Alcotest.(check int) "no readback after pre-effect failure" 1 !reads
;;

let test_materialize_transport_failure_does_not_launch_write () =
  with_materialization @@ fun ~base_path ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  state := Error (Masc.Keeper_sandbox_read_backend.Read_failed "guest unavailable");
  let result = invoke (fun () -> Alcotest.fail "must not write on unknown target state") in
  check_projected_manifest ~base_path result;
  Alcotest.(check int) "no write" 0 !writes;
  Alcotest.(check bool) "not classified as missing" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "this call did not mutate" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect)
;;

let test_materialize_verification_loss_does_not_repeat_effect () =
  with_materialization @@ fun ~base_path ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  let result = invoke (fun () ->
    state := Error (Masc.Keeper_sandbox_read_backend.Read_failed "read response lost");
    Keeper_tool_execution.success "written") in
  check_projected_manifest ~base_path result;
  Alcotest.(check bool) "unverified result remains failure" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "completed write phase retained" true
    (result.failure_effect_disposition = Tool_result.Proven_post_effect);
  Alcotest.(check int) "no write replay" 1 !writes
;;

let test_materialize_preserves_original_writer_evidence () =
  List.iter (fun recover ->
    with_materialization @@ fun ~base_path ~expected ~state ~reads:_ ~writes:_ ~invoke ->
    let root = match Tool_output.make_artifact_ref ~sha256:(String.make 64 'b')
        ~bytes:3 ~preview:"prior" ~mime:"text/plain" with
      | Ok reference -> reference
      | Error error -> Alcotest.fail (Tool_output.make_error_to_string error) in
    let data_root = match Tool_output.make_artifact_ref ~sha256:(String.make 64 'c')
        ~bytes:5 ~preview:"after" ~mime:"text/plain" with
      | Ok reference -> reference
      | Error error -> Alcotest.fail (Tool_output.make_error_to_string error) in
    let data = `Assoc ["snapshot", Tool_output.normalized_artifact_ref_to_json data_root] in
    let metadata = match Masc.Tool_bridge.attach_artifact_manifest ~base_path
        (Tool_result.make_ok ~tool_name:"write" ~start_time:(Tool_timing.start ()) ~data
          ~metadata:(`Assoc ["gate", `String "authorized-original-write"]) ()) with
      | Ok result -> Option.get (Tool_result.metadata result)
      | Error error -> Alcotest.fail error.message in
    let original = (if recover then
        Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
          ~metadata ~message:"write response lost" data
      else Keeper_tool_execution.success_data ~metadata data
        |> Keeper_tool_execution.with_file_change_evidence (Masc.Keeper_file_change_evidence.written expected))
      |> Keeper_tool_execution.with_retained_artifacts [root] in
    let result = invoke (fun () -> state := Ok (if recover then expected else "partial"); original) in
    Alcotest.(check bool) "original authorization metadata retained" true
      (Option.map (Yojson.Safe.Util.member "gate") result.metadata = Some (`String "authorized-original-write"));
    check_projected_manifest ~base_path result;
    Alcotest.(check bool) "original private roots retained" true (List.mem root result.retained_artifacts);
    let actual = match result.data with Some data -> data | None -> Alcotest.fail "lost typed result" in
    Alcotest.(check bool) "original typed data retained" true
      (Yojson.Safe.Util.member "write_result" actual = data);
    Alcotest.(check bool) "roots carried only by original typed data remain discoverable" true
      (List.mem data_root (Tool_output.normalized_artifact_refs_in_json actual));
    if recover then completed result
    else Alcotest.(check bool) "completed write line evidence survives failed verification" true
      (Yojson.Safe.Util.member "write_evidence" actual =
       Masc.Keeper_file_change_evidence.to_yojson (Masc.Keeper_file_change_evidence.written expected)))
    [false; true]
;;

let test_materialize_manifest_failure_keeps_effect_and_roots () =
  List.iter (fun recovered ->
    with_materialization @@ fun ~base_path ~expected ~state ~reads:_ ~writes ~invoke ->
    let store = Tool_blob_store.create ~base_path in
    let data_root = Tool_blob_store.put_durable store ~bytes:"original writer data" ~mime:"text/plain" in
    let private_root = Tool_blob_store.put_durable store ~bytes:"original private observer root" ~mime:"text/plain" in
    let writer_data = `Assoc ["snapshot", Tool_output.normalized_artifact_ref_to_json data_root] in
    let writer = match Masc.Tool_bridge.attach_artifact_manifest ~base_path
        (Tool_result.make_err ~tool_name:"write" ~class_:Tool_result.Runtime_failure
          ~start_time:(Tool_timing.start ()) ~data:writer_data
          ~metadata:(`Assoc ["gate", `String "original authorization"]) "response lost") with
      | Ok result -> result | Error error -> Alcotest.fail error.message in
    let old_manifest = match Masc.Tool_bridge.artifact_manifest_reference writer with
      | Ok (reference, _) -> reference | Error detail -> Alcotest.fail detail in
    let original = Keeper_tool_execution.of_tool_result writer
      |> Keeper_tool_execution.with_retained_artifacts [private_root] in
    let block_store () =
      let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path) in
      Unix.rename root (root ^ ".saved");
      write_file root "not a directory" in
    if not recovered then (state := Ok expected; block_store ());
    let result = invoke (fun () ->
      state := Ok expected;
      block_store ();
      original) in
    Alcotest.(check bool) "unpublished receipt remains a failure" true
      (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
    let phase = if recovered then Tool_result.Proven_post_effect else Tool_result.Proven_pre_effect in
    Alcotest.(check bool) "manifest failure keeps the proven phase" true
      (result.failure_effect_disposition = phase);
    Alcotest.(check int) "no write is replayed for publication failure" (if recovered then 1 else 0) !writes;
    Alcotest.(check bool) "raw diagnostic identifies manifest persistence" true
      (String_util.contains_substring result.raw_output "manifest could not be stored");
    Alcotest.(check bool) "artifact stays rooted" true
      (List.exists (fun (root : Tool_output.artifact_ref) ->
        root.sha256 = Agent_core_sha256.(digest_string expected |> to_hex)) result.retained_artifacts);
    Alcotest.(check bool) "no stale manifest binding" true (result.metadata = None);
    let receipt = Yojson.Safe.Util.member "result" (Option.get result.data) in
    Alcotest.(check bool) "unpublished exact verification remains inspectable" true
      Yojson.Safe.Util.(member "verified" receipt |> to_bool);
    if recovered then (
      Alcotest.(check bool) "unpublished receipt keeps original typed writer data" true
        (Yojson.Safe.Util.member "write_result" receipt = writer_data);
      Alcotest.(check bool) "old metadata stays evidence, not a new binding" true
        (Yojson.Safe.Util.member "producer_metadata" (Option.get result.data) = Option.get original.metadata);
      List.iter (fun root -> Alcotest.(check bool) "all original roots survive failed publication" true
        (List.mem root result.retained_artifacts)) [data_root; private_root; old_manifest]);
    match project_execution ~base_path result with
    | Ok _ -> Alcotest.fail "publication failure was presented as success"
    | Error error when recovered ->
      Alcotest.(check string) "model retains applied-effect warning" "proven_post_effect"
        Yojson.Safe.Util.(member "effect_disposition" (Yojson.Safe.from_string error.Agent_core.Types.message) |> to_string)
    | Error _ -> ()) [false; true]
;;

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  Eio_context.set_clock clock;
  Eio_context.set_switch sw;
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock;
  Alcotest.run
    "keeper peer artifact"
    [ ( "export ceiling"
      , [ Alcotest.test_case "an oversize export is refused" `Quick
            test_an_oversize_export_is_refused_rather_than_shortened
        ; Alcotest.test_case "an unwritable store root fails the export" `Quick
            test_an_unwritable_store_root_fails_the_export_not_the_dispatch
        ] )
    ; ( "recipient reconciliation"
      , [ Alcotest.test_case "verified repeat writes once" `Quick test_materialize_verifies_recipient_and_repeat_does_not_write
        ; Alcotest.test_case "matching prefix is not whole artifact" `Quick test_materialize_does_not_accept_a_matching_prefix
        ; Alcotest.test_case "lost response recovers without replay" `Quick test_materialize_recovers_lost_write_response_without_replay
        ; Alcotest.test_case "writer success requires recipient bytes" `Quick test_materialize_does_not_trust_success_without_bytes
        ; Alcotest.test_case "Gate deferral remains authoritative" `Quick test_materialize_preserves_gate_deferral
        ; Alcotest.test_case "pre-effect failure remains authoritative" `Quick test_materialize_preserves_pre_effect_failure
        ; Alcotest.test_case "transport fault is not missing target" `Quick test_materialize_transport_failure_does_not_launch_write
        ; Alcotest.test_case "verification loss never replays write" `Quick test_materialize_verification_loss_does_not_repeat_effect
        ; Alcotest.test_case "writer authorization and artifact evidence survive reconciliation" `Quick test_materialize_preserves_original_writer_evidence
        ; Alcotest.test_case "manifest failure preserves effect phase and artifact roots" `Quick test_materialize_manifest_failure_keeps_effect_and_roots
        ] )
    ]
;;
