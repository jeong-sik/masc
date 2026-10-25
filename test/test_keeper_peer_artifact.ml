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
(* An unwritable store root must come back as the export's own failure, the
   same typed path a failed atomic replacement takes: the handler translates
   [Sys_error] into the Failed Runtime_failure result that says why the bytes
   could not be stored. Before the store normalized directory creation the
   same setup escaped as a raw [Unix.Unix_error], skipping the handler's
   [Sys_error] arm and landing in the generic dispatch net with a message that
   never mentioned the store. *)
let test_an_unwritable_store_root_fails_the_export_not_the_dispatch () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  let masc_dir = Filename.concat base ".masc" in
  ensure_dir masc_dir;
  write_file (Filename.concat masc_dir "tool_blobs") "not a directory";
  let execution = run_export ~base ~emitting:8 in
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
  Alcotest.(check bool)
    "and names the operating system's reason"
    true
    (String_util.contains_substring said "mkdir");
  Alcotest.(check bool)
    "with the reason's readable message, as the store contract renders it \
     (not the raw exception's ENOTDIR spelling)"
    true
    (String_util.contains_substring said "Not a directory")
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
  let invoke write = Keeper_peer_artifact.materialize ~artifact ~path:"proof.bin"
      ~fetch:(fun () -> Ok expected) ~read ~write:(fun () -> incr writes; write ()) in
  f ~expected ~state ~reads ~writes ~invoke
;;

let completed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ -> Alcotest.fail result.raw_output
;;

let test_materialize_verifies_recipient_and_repeat_does_not_write () =
  with_materialization @@ fun ~expected ~state ~reads:_ ~writes ~invoke ->
  let write () = state := Ok expected; Keeper_tool_execution.success_data (`Assoc ["ok", `Bool true]) in
  completed (invoke write);
  completed (invoke write);
  Alcotest.(check int) "one write, verified repeat only reads" 1 !writes
;;

let test_materialize_does_not_accept_a_matching_prefix () =
  with_materialization @@ fun ~expected ~state ~reads:_ ~writes ~invoke ->
  state := Ok (expected ^ "extra");
  completed (invoke (fun () -> state := Ok expected; Keeper_tool_execution.success "written"));
  Alcotest.(check int) "longer target must be replaced" 1 !writes
;;

let test_materialize_recovers_lost_write_response_without_replay () =
  with_materialization @@ fun ~expected ~state ~reads ~writes ~invoke ->
  let result = invoke (fun () ->
    state := Ok expected;
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure "response lost") in
  completed result;
  Alcotest.(check int) "uncertain write is never replayed" 1 !writes;
  Alcotest.(check int) "read reconciles the uncertain result" 2 !reads;
  Alcotest.(check bool) "completion is verified" true
    Yojson.Safe.Util.(member "verified" (Option.get result.data) |> to_bool);
  Alcotest.(check bool) "recovery is explicit" true
    Yojson.Safe.Util.(member "recovered" (Option.get result.data) |> to_bool)
;;

let test_materialize_does_not_trust_success_without_bytes () =
  with_materialization @@ fun ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  let result = invoke (fun () -> state := Ok "partial"; Keeper_tool_execution.success "written") in
  Alcotest.(check bool) "mismatching write is not completion" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "write effect remains recorded" true
    (result.failure_effect_disposition = Tool_result.Proven_post_effect);
  Alcotest.(check int) "no blind corrective write" 1 !writes
;;

let test_materialize_preserves_gate_deferral () =
  with_materialization @@ fun ~expected ~state ~reads ~writes:_ ~invoke ->
  let deferred = Keeper_tool_execution.deferred_external_effect_data ~approval_id:"exact-approval" (`Assoc []) in
  let result = invoke (fun () -> state := Ok expected; deferred) in
  Alcotest.(check bool) "Gate receipt is unchanged" true (result == deferred);
  Alcotest.(check int) "no post-read turns a Gate decision into success" 1 !reads
;;

let test_materialize_preserves_pre_effect_failure () =
  with_materialization @@ fun ~expected ~state ~reads ~writes:_ ~invoke ->
  let refused = Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect "writer refused before mutation" in
  let result = invoke (fun () -> state := Ok expected; refused) in
  Alcotest.(check bool) "producer phase remains authoritative" true (result == refused);
  Alcotest.(check int) "no readback after pre-effect failure" 1 !reads
;;

let test_materialize_transport_failure_does_not_launch_write () =
  with_materialization @@ fun ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  state := Error (Masc.Keeper_sandbox_read_backend.Read_failed "guest unavailable");
  let result = invoke (fun () -> Alcotest.fail "must not write on unknown target state") in
  Alcotest.(check int) "no write" 0 !writes;
  Alcotest.(check bool) "not classified as missing" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "this call did not mutate" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect)
;;

let test_materialize_verification_loss_does_not_repeat_effect () =
  with_materialization @@ fun ~expected:_ ~state ~reads:_ ~writes ~invoke ->
  let result = invoke (fun () ->
    state := Error (Masc.Keeper_sandbox_read_backend.Read_failed "read response lost");
    Keeper_tool_execution.success "written") in
  Alcotest.(check bool) "unverified result remains failure" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "completed write phase retained" true
    (result.failure_effect_disposition = Tool_result.Proven_post_effect);
  Alcotest.(check int) "no write replay" 1 !writes
;;

let test_materialize_preserves_original_writer_evidence () =
  List.iter (fun recover ->
    with_materialization @@ fun ~expected ~state ~reads:_ ~writes:_ ~invoke ->
    let root = match Tool_output.make_artifact_ref ~sha256:(String.make 64 'b')
        ~bytes:3 ~preview:"prior" ~mime:"text/plain" with
      | Ok reference -> reference
      | Error error -> Alcotest.fail (Tool_output.make_error_to_string error) in
    let data_root = match Tool_output.make_artifact_ref ~sha256:(String.make 64 'c')
        ~bytes:5 ~preview:"after" ~mime:"text/plain" with
      | Ok reference -> reference
      | Error error -> Alcotest.fail (Tool_output.make_error_to_string error) in
    let metadata = `Assoc ["gate", `String "authorized-original-write"] in
    let data = `Assoc ["snapshot", Tool_output.normalized_artifact_ref_to_json data_root] in
    let original = (if recover then
        Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
          ~metadata ~message:"write response lost" data
      else Keeper_tool_execution.success_data ~metadata data
        |> Keeper_tool_execution.with_file_change_evidence (Masc.Keeper_file_change_evidence.written expected))
      |> Keeper_tool_execution.with_retained_artifacts [root] in
    let result = invoke (fun () -> state := Ok (if recover then expected else "partial"); original) in
    Alcotest.(check bool) "original authorization metadata retained" true (result.metadata = Some metadata);
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
        ] )
    ]
;;
