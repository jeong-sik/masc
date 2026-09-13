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
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "peer-exporter" ]) with
    | Ok meta ->
      { meta with
        Masc.Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Docker
      ; sandbox_image = Some "alpine:test"
      }
    | Error detail -> Alcotest.fail detail
  in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir (Filename.concat host_root "scratch");
  write_file (Filename.concat host_root "scratch/artifact.bin") (String.make emitting 'x');
  with_fake_docker_emitting ~bytes:emitting @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
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
        ] )
    ]
;;
