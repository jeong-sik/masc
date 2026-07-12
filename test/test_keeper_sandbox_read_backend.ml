(** Tests for Keeper_sandbox_read_backend.

    RFC-0006 Phase B-2: docker-routed reads for Docker keepers.
    These tests cover the pure path-mapping and routing logic;
    the actual [docker run] call is exercised only in environments
    where docker is available, gated through env-set integration
    tests. *)

module Workspace = Masc.Workspace
module Keeper_sandbox_read_backend = Masc.Keeper_sandbox_read_backend
module Keeper_turn_sandbox_runtime = Masc.Keeper_turn_sandbox_runtime
module Keeper_sandbox_factory = Masc.Keeper_sandbox_factory
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Fd_accountant = Fd_accountant
module Env_config_keeper = Env_config_keeper

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let d = Filename.temp_file "keeper_sandbox_read_backend_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if nlen = 0 then true
    else if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  loop 0

let env_file_path_from_docker_line line =
  let rec loop = function
    | "--env-file" :: path :: _ -> Some path
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (String.split_on_char ' ' line)

let docker_spawn_in_flight () =
  let snapshot = Fd_accountant.fd_snapshot () in
  List.assoc Fd_accountant.Docker_spawn snapshot.per_kind

let wait_until ~clock ~attempts predicate =
  let rec loop remaining =
    if predicate () then true
    else if remaining <= 0 then false
    else (
      Eio.Time.sleep clock 0.001;
      loop (remaining - 1))
  in
  loop attempts

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "docker read test");
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

(* ── should_route_read profile policy ────────────────────────────── *)

let test_legacy_keeper_never_routes () =
  let meta = make_meta ~name:"alice" ~sandbox:Keeper_types_profile_sandbox.Local in
  Alcotest.(check bool) "legacy keeper never routes through docker"
    false
    (Keeper_sandbox_read_backend.should_route_read ~meta)

let test_docker_keeper_routes () =
  let meta =
    make_meta ~name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  Alcotest.(check bool) "docker keeper routes through docker"
    true
    (Keeper_sandbox_read_backend.should_route_read ~meta)

let test_docker_second_keeper_routes () =
  let meta =
    make_meta ~name:"poe" ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  Alcotest.(check bool) "docker second keeper also routes" true
    (Keeper_sandbox_read_backend.should_route_read ~meta)

(* ── container_path_of_host pure mapping ─────────────────────────── *)

let setup_config name =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base Common.masc_dirname) 0o755;
  let config = Workspace.default_config base in
  let meta =
    make_meta ~name ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  base, config, meta

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path f

let test_container_path_root_maps () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta
      ~host_path:host_root
  with
  | Ok mapped ->
      Alcotest.(check string) "host playground root maps to container root"
        croot mapped
  | Error e -> Alcotest.fail e

let test_container_path_nested_maps_with_suffix () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_path = Filename.concat host_root "mind/scratch.md" in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta ~host_path
  with
  | Ok mapped ->
      Alcotest.(check string)
        "host nested path maps with suffix"
        (Filename.concat croot "mind/scratch.md")
        mapped
  | Error e -> Alcotest.fail e

let test_container_path_outside_playground_errors () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let outside = "/etc/passwd" in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta
      ~host_path:outside
  with
  | Ok mapped ->
      Alcotest.failf
        "expected error for outside-playground path, got Ok %s" mapped
  | Error _ -> ()

(* ── Integration: read_file error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_read_outside_playground_returns_mapping_error () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta
      ~host_path:"/etc/passwd" ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected mapping error for /etc/passwd"
  | Error msg ->
      Alcotest.(check bool) "error mentions playground" true
        (let needle = "playground" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_read_missing_file_preflight_errors () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_path = Filename.concat host_root "mind/x" in
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta ~host_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected missing-file preflight error"
  | Error msg ->
      Alcotest.(check bool) "error mentions path_not_found" true
        (let needle = "path_not_found" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

(* Read on a directory must point the keeper at a tool that actually
   exists. The old message said "use the currently exposed read/listing
   tools" without naming one; the current surface directs agents to
   Execute ls. Guards against the message regressing to a phantom-tool
   reference. *)
let test_read_directory_names_a_real_listing_tool () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let dir_path = Filename.concat host_root "mind/somedir" in
  ensure_dir dir_path;
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta ~host_path:dir_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected path_is_directory error for a directory"
  | Error msg ->
      Alcotest.(check bool) "error reports path_is_directory" true
        (contains_substring msg "path_is_directory");
      Alcotest.(check bool)
        "error names a real listing command"
        true
        (contains_substring msg "executable='ls'")

(* ── run_command error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_run_command_empty_argv_errors () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command ~config ~meta
      ~command_argv:[] ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected error for empty command_argv"
  | Error msg ->
      Alcotest.(check bool) "mentions empty command_argv" true
        (let needle = "command_argv is empty" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_empty_image_errors () =
  let base, config, meta = setup_config "minjae" in
  let meta = { meta with sandbox_image = Some "" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command ~config ~meta
      ~command_argv:[ "ls"; "/" ] ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected image-config error"
  | Error msg ->
      Alcotest.(check bool) "mentions docker image" true
        (let needle = "docker image" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let fake_docker_exit_1_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  printf 'no matches\\n'\n\
  exit 1\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_echo_command_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation\\n' >&2\n\
  exit 2\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
printf '%s\\n' \"$*\"\n\
exit 0\n"

let fake_docker_slow_run_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  if [ -n \"$log_file\" ]; then\n\
    printf 'run-started\\n' >> \"$log_file\"\n\
  fi\n\
  sleep 0.2\n\
  printf 'slow ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_log_run_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  printf 'ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_env_dump_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  env > \"${MASC_KEEPER_TEST_DOCKER_LOG}.env\"\n\
  printf 'ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_turn_runtime_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    case \"$*\" in\n\
      *stderr-only*)\n\
        printf 'only stderr\\n' >&2\n\
        exit 7\n\
        ;;\n\
    esac\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_stale_streaming_retry_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
inspect_count_file=${KEEPER_DOCKER_INSPECT_COUNT:-}\n\
exec_count_file=${KEEPER_DOCKER_EXEC_COUNT:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() {\n\
  if [ -n \"$1\" ] && [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  if [ -n \"$1\" ]; then\n\
    printf '%s' \"$2\" > \"$1\"\n\
  fi\n\
}\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  ps)\n\
    # The failed state inspect is followed by an exact-name inventory probe.\n\
    # Empty successful output proves that the cached container disappeared.\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    count=$(read_count \"$inspect_count_file\")\n\
    count=$((count + 1))\n\
    write_count \"$inspect_count_file\" \"$count\"\n\
    if [ \"$count\" = \"2\" ]; then\n\
      printf 'synthetic opaque state inspection failure\\n' >&2\n\
      exit 1\n\
    fi\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    exec_count=$(read_count \"$exec_count_file\")\n\
    exec_count=$((exec_count + 1))\n\
    write_count \"$exec_count_file\" \"$exec_count\"\n\
    inspect_count=$(read_count \"$inspect_count_file\")\n\
    if [ \"$exec_count\" = \"2\" ] && [ \"$inspect_count\" -lt 2 ]; then\n\
      printf 'synthetic opaque exec failure\\n' >&2\n\
      exit 127\n\
    fi\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_stopped_streaming_retry_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
state_dir=$(dirname \"$0\")\n\
run_count_file=\"$state_dir/stopped-run.count\"\n\
exec_count_file=\"$state_dir/stopped-exec.count\"\n\
state_inspect_count_file=\"$state_dir/stopped-state-inspect.count\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() {\n\
  if [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  if [ -n \"$1\" ]; then\n\
    printf '%s' \"$2\" > \"$1\"\n\
  fi\n\
}\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    count=$(read_count \"$run_count_file\")\n\
    count=$((count + 1))\n\
    write_count \"$run_count_file\" \"$count\"\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
        count=$(read_count \"$state_inspect_count_file\")\n\
        count=$((count + 1))\n\
        write_count \"$state_inspect_count_file\" \"$count\"\n\
        if [ \"$count\" = \"1\" ]; then\n\
          printf 'false\\n'\n\
        else\n\
          printf 'true\\n'\n\
        fi\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    exec_count=$(read_count \"$exec_count_file\")\n\
    exec_count=$((exec_count + 1))\n\
    write_count \"$exec_count_file\" \"$exec_count\"\n\
    run_count=$(read_count \"$run_count_file\")\n\
    if [ \"$exec_count\" = \"2\" ] && [ \"$run_count\" -lt 2 ]; then\n\
      printf 'synthetic opaque stopped-container exec failure\\n' >&2\n\
      exit 126\n\
    fi\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_eintr_streaming_retry_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
state_dir=$(dirname \"$0\")\n\
exec_count_file=\"$state_dir/eintr-exec.count\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() {\n\
  if [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  if [ -n \"$1\" ]; then\n\
    printf '%s' \"$2\" > \"$1\"\n\
  fi\n\
}\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
        printf 'true\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    case \"$*\" in\n\
      *marker-prefix-progress*)\n\
        printf 'inter'\n\
        sleep 1\n\
        printf 'done\\n'\n\
        exit 0\n\
        ;;\n\
      *slow-timeout*)\n\
        sleep 2\n\
        printf 'late\\n'\n\
        exit 0\n\
        ;;\n\
      *sparse-progress*)\n\
        printf 'ready\\n'\n\
        sleep 1\n\
        printf 'done\\n'\n\
        exit 0\n\
        ;;\n\
      *progress*)\n\
        printf 'progress-1\\n'\n\
        sleep 1\n\
        printf 'progress-2\\n'\n\
        sleep 1\n\
        printf 'done\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    exec_count=$(read_count \"$exec_count_file\")\n\
    exec_count=$((exec_count + 1))\n\
    write_count \"$exec_count_file\" \"$exec_count\"\n\
    if [ \"$exec_count\" = \"2\" ]; then\n\
      case \"$*\" in\n\
        *early-eintr*)\n\
          printf 'early-progress\\n'\n\
          sleep 0.3\n\
          printf 'retry-only stderr: interrupted system call\\n' >&2\n\
          exit 127\n\
          ;;\n\
        *split-eintr*)\n\
          printf 'retry-only stdout a\\n'\n\
          sleep 0.05\n\
          printf 'retry-only stdout b\\n'\n\
          printf 'interrupted sys' >&2\n\
          sleep 0.01\n\
          printf 'tem call\\n' >&2\n\
          exit 127\n\
          ;;\n\
      esac\n\
      printf 'retry-only stdout\\n'\n\
      printf 'retry-only stderr: interrupted system call\\n' >&2\n\
      exit 127\n\
    fi\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_ok_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf ''\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_missing_image_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    printf 'Error: No such image: %s\\n' \"$3\" >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'run should not execute when image inspect fails\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_daemon_unavailable_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\\n' >&2\n\
    exit 1\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'unexpected image inspect\\n' >&2\n\
    exit 2\n\
    ;;\n\
  run)\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_image_timeout_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    printf 'process error: timeout after 5s\\n' >&2\n\
    exit 124\n\
    ;;\n\
  run)\n\
    printf 'run should not execute when image inspect times out\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_oci_mount_failure_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'docker: Error response from daemon: failed to create shim task: OCI runtime create failed: error during container init: error mounting \"/host/path\" to rootfs at \"/container/path\": no such file or directory.\\n' >&2\n\
    exit 1\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_startup_preflight_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'startup preflight must not run image command inventory\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_cleanup_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  ps)\n\
    printf 'old-container\\nfresh-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    last=''\n\
    for arg in \"$@\"; do last=\"$arg\"; done\n\
    case \"$last\" in\n\
      old-container)\n\
        printf '999999\\t100.000\\ttrue\\t600\\n'\n\
        exit 0\n\
        ;;\n\
      fresh-container)\n\
        printf '%s\\t990.000\\ttrue\\t600\\n' \"${KEEPER_TEST_PID:-1}\"\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'unexpected inspect target: %s\\n' \"$last\" >&2\n\
    exit 2\n\
    ;;\n\
  rm)\n\
    if [ \"$2\" = \"-f\" ] && [ \"$3\" = \"-v\" ] && [ \"$4\" = \"old-container\" ]; then\n\
      printf 'old-container\\n'\n\
      exit 0\n\
    fi\n\
    printf 'unexpected rm target\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_cleanup_fail_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  ps)\n\
    printf 'docker daemon unavailable\\n' >&2\n\
    exit 1\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_cleanup_disappeared_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  ps)\n\
    for arg in \"$@\"; do\n\
      case \"$arg\" in\n\
        id=*) exit 0 ;;\n\
      esac\n\
    done\n\
    printf 'inspect-gone\\nrm-gone\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    last=''\n\
    for arg in \"$@\"; do last=\"$arg\"; done\n\
    case \"$last\" in\n\
      inspect-gone)\n\
        printf 'synthetic inspect failure\\n' >&2\n\
        exit 1\n\
        ;;\n\
      rm-gone)\n\
        printf '\\t100.000\\tfalse\\t600\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'unexpected inspect target: %s\\n' \"$last\" >&2\n\
    exit 2\n\
    ;;\n\
  rm)\n\
    if [ \"$2\" = \"-f\" ] && [ \"$3\" = \"-v\" ] && [ \"$4\" = \"rm-gone\" ]; then\n\
      printf 'synthetic remove failure\\n' >&2\n\
      exit 1\n\
    fi\n\
    printf 'unexpected rm target\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_cleanup_present_failure_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  ps)\n\
    printf 'present-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    printf 'synthetic inspect failure while container remains present\\n' >&2\n\
    exit 1\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let test_sandbox_container_label_args_include_owner_scope () =
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~base_path:"/tmp/masc"
      ~keeper_name:"min/jae"
      ~container_kind:
        (Keeper_types_profile_sandbox.sandbox_container_kind_to_string
           Keeper_types_profile_sandbox.Sandbox_turn)
      ~network_label:"none" ()
  in
  let has_label value = List.mem value args in
  let has_label_prefix prefix =
    List.exists (String.starts_with ~prefix) args
  in
  Alcotest.(check bool) "component label" true
    (has_label "masc.mcp.component=keeper-sandbox");
  Alcotest.(check bool) "base path hash label" true
    (has_label_prefix "masc.mcp.base_path_hash=");
  Alcotest.(check bool) "sanitized keeper label" true
    (has_label "masc.mcp.keeper=min_jae");
  Alcotest.(check bool) "kind label" true
    (has_label "masc.mcp.kind=turn");
  Alcotest.(check bool) "owner pid label" true
    (has_label
       ("masc.mcp.owner_pid=" ^ string_of_int (Unix.getpid ())));
  Alcotest.(check bool) "started_at label" true
    (has_label_prefix "masc.mcp.started_at=");
  Alcotest.(check bool) "network label" true
    (has_label "masc.mcp.network=none")

let test_base_path_hash_relative_input_anchors_to_cwd_not_env_base () =
  let root = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir root) @@ fun () ->
  let cwd = Filename.concat root "cwd" in
  let env_base = Filename.concat root "env-base" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir env_base 0o755;
  let saved_cwd = Sys.getcwd () in
  with_env "MASC_BASE_PATH" env_base @@ fun () ->
  Fun.protect
    ~finally:(fun () -> Sys.chdir saved_cwd)
    (fun () ->
       Sys.chdir cwd;
       Alcotest.(check string)
         "relative base hash anchor"
         (Filename.concat (Unix.realpath cwd) "relative-base")
         (Keeper_sandbox_runtime.normalize_base_path_for_hash "relative-base"))

let test_sandbox_container_label_args_include_oneshot_ttl () =
  let container_kind =
    Keeper_types_profile_sandbox.sandbox_container_kind_to_string
      Keeper_types_profile_sandbox.Sandbox_oneshot
  in
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~ttl_sec:90.0
      ~base_path:"/tmp/masc"
      ~keeper_name:"issue-king"
      ~container_kind
      ~network_label:"host" ()
  in
  let has_label value = List.mem value args in
  Alcotest.(check bool) "oneshot kind label" true
    (has_label ("masc.mcp.kind=" ^ container_kind));
  Alcotest.(check bool) "ttl label" true
    (has_label "masc.mcp.ttl_sec=90");
  Alcotest.(check bool) "host network label" true
    (has_label "masc.mcp.network=host")

let test_docker_network_args_follow_masc_policy () =
  let args_none, label_none =
    Keeper_sandbox_runtime.docker_network_args Keeper_types_profile_sandbox.Network_none
  in
  Alcotest.(check (list string)) "network none passes docker flag"
    [ "--network"; "none" ] args_none;
  Alcotest.(check string) "network none label" "none" label_none;
  let args_host, label_host =
    Keeper_sandbox_runtime.docker_network_args Keeper_types_profile_sandbox.Network_host
  in
  Alcotest.(check (list string)) "host network uses host network (#10431)"
    [ "--network"; "host" ] args_host;
  Alcotest.(check string) "host network label" "host" label_host

let test_docker_nofile_args_follow_config () =
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "not-a-number" @@ fun () ->
  Alcotest.(check (list string)) "default nofile limit"
    [ "--ulimit"; "nofile=245760:245760" ]
    (Keeper_sandbox_runtime.docker_nofile_args ());
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "8192" @@ fun () ->
  Alcotest.(check (list string)) "configured nofile limit"
    [ "--ulimit"; "nofile=8192:8192" ]
    (Keeper_sandbox_runtime.docker_nofile_args ());
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "256" @@ fun () ->
  Alcotest.(check (list string)) "nofile floor"
    [ "--ulimit"; "nofile=1024:1024" ]
    (Keeper_sandbox_runtime.docker_nofile_args ())

let test_docker_masc_config_binding_pins_container_runtime_paths () =
  let base = "/tmp/masc-base" in
  let container_root = "/home/keeper/playground/minjae" in
  let expected_host_config =
    Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config"
  in
  Alcotest.(check string)
    "host config dir"
    expected_host_config
    (Keeper_sandbox_runtime.host_masc_config_dir ~base_path:base);
  Alcotest.(check string)
    "container config dir"
    "/tmp/masc-runtime/.masc/config"
    (Keeper_sandbox_runtime.container_masc_config_dir ~container_root);
  Alcotest.(check (list string))
    "runtime env args"
    [ "--env"
    ; "MASC_BASE_PATH=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_CONFIG_DIR=/tmp/masc-runtime/.masc/config"
    ]
    (Keeper_sandbox_runtime.docker_masc_runtime_env_args ~container_root);
  Alcotest.(check (list string))
    "config bind mount"
    [ "-v"
    ; expected_host_config ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_masc_config_mount_args
       ~base_path:base
       ~container_root)

let test_docker_config_mount_and_env_args () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config_root = Filename.concat base ".masc/config" in
  ensure_dir config_root;
  let container_root = "/home/keeper/playground/minjae" in
  with_env "MASC_CONFIG_DIR" "" @@ fun () ->
  Alcotest.(check string) "default host config root"
    config_root
    (Keeper_sandbox_runtime.docker_config_host_root ~base_path:base);
  Alcotest.(check (list string)) "default config mount"
    [ "-v"
    ; config_root ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_config_mount_args
       ~base_path:base
       ~container_root);
  Alcotest.(check (list string)) "default config env"
    [ "--env"
    ; "MASC_BASE_PATH=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_BASE_PATH_INPUT=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_CONFIG_DIR=/tmp/masc-runtime/.masc/config"
    ]
    (Keeper_sandbox_runtime.docker_config_env_args
       ~base_path:base
       ~container_root);
  let override_base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir override_base) @@ fun () ->
  let override_root = Filename.concat override_base "config" in
  ensure_dir override_root;
  with_env "MASC_CONFIG_DIR" override_root @@ fun () ->
  Alcotest.(check string) "override host config root"
    override_root
    (Keeper_sandbox_runtime.docker_config_host_root ~base_path:base);
  Alcotest.(check (list string)) "override config mount"
    [ "-v"
    ; override_root ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_config_mount_args
       ~base_path:base
       ~container_root)

let test_docker_run_looks_daemon_pressure_does_not_retry_timeout () =
  Alcotest.(check bool)
    "WEXITED 124 with timeout output is not daemon pressure"
    false
    (Keeper_sandbox_runtime.docker_run_looks_daemon_pressure
       ~status:(Unix.WEXITED 124)
       ~output:"process error: timeout after 5s")

let test_docker_run_looks_daemon_pressure_classifies_daemon_unavailable () =
  Alcotest.(check bool)
    "daemon unavailable output is daemon pressure"
    true
    (Keeper_sandbox_runtime.docker_run_looks_daemon_pressure
       ~status:(Unix.WEXITED 1)
       ~output:"Cannot connect to the Docker daemon at unix:///var/run/docker.sock")

let test_docker_run_looks_daemon_pressure_not_pressure_on_command_error () =
  Alcotest.(check bool)
    "normal command failure is not daemon pressure"
    false
    (Keeper_sandbox_runtime.docker_run_looks_daemon_pressure
       ~status:(Unix.WEXITED 1)
       ~output:"No such file or directory")

let test_docker_run_looks_daemon_pressure_not_pressure_on_connection_refused () =
  Alcotest.(check bool)
    "generic connection refused output is not Docker daemon pressure"
    false
    (Keeper_sandbox_runtime.docker_run_looks_daemon_pressure
       ~status:(Unix.WEXITED 1)
       ~output:"connection refused")

let test_docker_failure_class_is_typed_and_serializes_stable_string () =
  let open Masc.Keeper_sandbox_runtime_classify in
  Alcotest.(check string)
    "daemon unavailable class serializes to stable string"
    "docker_daemon_unavailable"
    (docker_failure_class_to_string Docker_daemon_unavailable);
  Alcotest.(check string)
    "command timeout class serializes to stable string"
    "docker_command_timeout"
    (docker_failure_class_to_string Docker_command_timeout);
  Alcotest.(check bool)
    "classifier maps daemon unavailable output to the typed variant"
    true
    (match
       classify_docker_run_failure
         ~status:(Unix.WEXITED 1)
         ~output:"Cannot connect to the Docker daemon"
     with
     | Docker_daemon_unavailable -> true
     | _ -> false);
  Alcotest.(check bool)
    "run classifier maps timeout output to Docker_command_timeout, not Docker_daemon_timeout"
    true
    (match
       classify_docker_run_failure
         ~status:(Unix.WEXITED 124)
         ~output:"process error: timeout after 5s"
     with
     | Docker_command_timeout -> true
     | _ -> false);
  Alcotest.(check bool)
    "info classifier maps timeout output to Docker_daemon_timeout"
    true
    (match
       classify_docker_info_failure
         ~status:(Unix.WEXITED 124)
         ~output:"process error: timeout after 5s"
     with
     | Docker_daemon_timeout -> true
     | _ -> false)

let test_docker_workspace_state_mount_args_expose_safe_subset () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let masc_root = Filename.concat base ".masc" in
  ensure_dir (Filename.concat masc_root "tasks");
  write_file (Filename.concat (Filename.concat masc_root "tasks") "backlog.json") "{}";
  write_file (Filename.concat masc_root "board_posts.jsonl") "";
  ensure_dir (Filename.concat masc_root "auth");
  write_file (Filename.concat (Filename.concat masc_root "auth") "keeper.token") "secret";
  let container_root = "/home/keeper/playground/minjae" in
  let specs =
    Keeper_sandbox_runtime.docker_workspace_state_mount_specs
      ~base_path:base
      ~container_root
  in
  let tasks_host = Filename.concat masc_root "tasks" in
  let board_host = Filename.concat masc_root "board_posts.jsonl" in
  Alcotest.(check bool) "mounts tasks under runtime .masc" true
    (List.mem
       (tasks_host ^ ":/tmp/masc-runtime/.masc/tasks:ro")
       specs);
  Alcotest.(check bool) "does not mount tasks at host absolute target" false
    (List.mem (tasks_host ^ ":" ^ tasks_host ^ ":ro") specs);
  Alcotest.(check bool) "mounts board posts" true
    (List.mem
       (board_host ^ ":/tmp/masc-runtime/.masc/board_posts.jsonl:ro")
       specs);
  Alcotest.(check bool) "all targets stay under runtime .masc" true
    (List.for_all
       (fun spec ->
         match String.split_on_char ':' spec with
         | [ _source; target; "ro" ] ->
           String.starts_with ~prefix:"/tmp/masc-runtime/.masc/" target
         | _ -> false)
       specs);
  Alcotest.(check bool) "no targets nested under playground bind mount" true
    (List.for_all
       (fun spec ->
         match String.split_on_char ':' spec with
         | [ _source; target; "ro" ] ->
           not (String.starts_with ~prefix:(container_root ^ "/") target)
         | _ -> false)
       specs);
  Alcotest.(check bool) "does not mount auth" false
    (List.exists (fun spec -> contains_substring spec "/auth/") specs)

let test_cleanup_stale_containers_removes_only_stale_masc_scope () =
  with_fake_docker fake_docker_cleanup_script @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "KEEPER_TEST_PID" (string_of_int (Unix.getpid ())) @@ fun () ->
  let result =
    Keeper_sandbox_runtime.cleanup_stale_containers
      ~now:1000.0
      ~max_age_sec:60.0
      ~base_path:base
      ~timeout_sec:5.0 ()
  in
  Alcotest.(check int) "scanned labeled containers" 2 result.scanned;
  Alcotest.(check int) "removed stale container" 1 result.removed;
  Alcotest.(check int) "no concurrent disappearance" 0 result.already_absent;
  Alcotest.(check (list string)) "no cleanup errors" [] result.errors;
  let log = read_file log_path in
  Alcotest.(check bool) "removes old container" true
    (contains_substring log "rm -f -v old-container");
  Alcotest.(check bool) "keeps fresh container" false
    (contains_substring log "rm -f -v fresh-container")

let test_cleanup_stale_containers_accepts_concurrent_disappearance () =
  with_fake_docker fake_docker_cleanup_disappeared_script @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let result =
    Keeper_sandbox_runtime.cleanup_stale_containers
      ~now:1000.0
      ~max_age_sec:60.0
      ~base_path:base
      ~timeout_sec:5.0 ()
  in
  Alcotest.(check int) "scanned snapshot containers" 2 result.scanned;
  Alcotest.(check int) "no container removed by this sweep" 0 result.removed;
  Alcotest.(check int) "both disappearance races observed" 2 result.already_absent;
  Alcotest.(check (list string)) "disappearance is not an error" [] result.errors;
  let log = read_file log_path in
  Alcotest.(check bool)
    "inspect-absent container is not removed again"
    false
    (contains_substring log "rm -f -v inspect-gone");
  Alcotest.(check bool)
    "remove race reaches docker rm"
    true
    (contains_substring log "rm -f -v rm-gone")

let test_cleanup_stale_containers_preserves_present_failure () =
  with_fake_docker fake_docker_cleanup_present_failure_script @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let result =
    Keeper_sandbox_runtime.cleanup_stale_containers
      ~now:1000.0
      ~max_age_sec:60.0
      ~base_path:base
      ~timeout_sec:5.0 ()
  in
  Alcotest.(check int) "scanned present container" 1 result.scanned;
  Alcotest.(check int) "present container is not removed" 0 result.removed;
  Alcotest.(check int) "present container is not called absent" 0 result.already_absent;
  match result.errors with
  | [ error ] ->
    Alcotest.(check bool)
      "original inspect failure remains explicit"
      true
      (contains_substring error "synthetic inspect failure")
  | errors -> Alcotest.failf "expected one explicit cleanup error, got %d" (List.length errors)

let test_maybe_cleanup_disappearance_does_not_activate_backoff () =
  with_fake_docker fake_docker_cleanup_disappeared_script @@ fun () ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
      cleanup_dir base)
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC" "10" @@ fun () ->
  Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
  let first =
    Keeper_sandbox_runtime.maybe_cleanup_stale_containers
      ~now:1000.0
      ~base_path:base
      ~timeout_sec:5.0 ()
  in
  (match first with
   | Some result ->
     Alcotest.(check int) "first sweep records both races" 2 result.already_absent;
     Alcotest.(check (list string)) "first sweep has no errors" [] result.errors
   | None -> Alcotest.fail "expected first cleanup sweep to run");
  let second =
    Keeper_sandbox_runtime.maybe_cleanup_stale_containers
      ~now:1011.0
      ~base_path:base
      ~timeout_sec:5.0 ()
  in
  Alcotest.(check bool)
    "normal interval remains eligible after disappearance"
    true
    (Option.is_some second)

let test_maybe_cleanup_stale_containers_runs_once_per_interval () =
  with_fake_docker fake_docker_cleanup_script @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
      cleanup_dir base)
  @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "KEEPER_TEST_PID" (string_of_int (Unix.getpid ())) @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC" "10" @@ fun () ->
  Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
  let results = ref [] in
  (Eio.Switch.run @@ fun sw ->
   for _ = 1 to 16 do
     Eio.Fiber.fork ~sw (fun () ->
       let result =
         Keeper_sandbox_runtime.maybe_cleanup_stale_containers
           ~base_path:base
           ~timeout_sec:5.0
           ()
       in
       results := result :: !results)
   done);
  let ran =
    List.fold_left
      (fun acc -> function
         | Some _ -> acc + 1
         | None -> acc)
      0
      !results
  in
  Alcotest.(check int) "only one cleanup sweep enters per interval" 1 ran;
  let cleanup_snapshot_count =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.filter (fun line ->
      String.starts_with ~prefix:"ps -aq " line
      && contains_substring
           line
           "label=masc.mcp.component=keeper-sandbox")
    |> List.length
  in
  Alcotest.(check int)
    "only one labeled cleanup snapshot"
    1
    cleanup_snapshot_count

let test_maybe_cleanup_stale_containers_backs_off_after_failure () =
  with_fake_docker fake_docker_cleanup_fail_script @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
      cleanup_dir base)
  @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC" "10" @@ fun () ->
  Keeper_sandbox_runtime.reset_last_cleanup_for_tests ();
  let first =
    Keeper_sandbox_runtime.maybe_cleanup_stale_containers
      ~now:1000.0 ~base_path:base ~timeout_sec:5.0 ()
  in
  (match first with
   | Some result ->
       Alcotest.(check bool) "first cleanup records daemon error" true
         (result.errors <> [])
   | None -> Alcotest.fail "expected first cleanup to run");
  let skipped =
    Keeper_sandbox_runtime.maybe_cleanup_stale_containers
      ~now:1011.0 ~base_path:base ~timeout_sec:5.0 ()
  in
  Alcotest.(check bool) "failure backoff skips next interval" true
    (Option.is_none skipped);
  let after_backoff =
    Keeper_sandbox_runtime.maybe_cleanup_stale_containers
      ~now:2801.0 ~base_path:base ~timeout_sec:5.0 ()
  in
  Alcotest.(check bool) "cleanup runs after failure backoff" true
    (Option.is_some after_backoff);
  let ps_count =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.filter (String.starts_with ~prefix:"ps -aq ")
    |> List.length
  in
  Alcotest.(check int) "backoff suppresses one docker ps cleanup spawn" 2
    ps_count

let test_docker_preflight_reports_ready_image () =
  with_fake_docker fake_docker_preflight_ok_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight ok" true preflight.ok;
      Alcotest.(check bool) "image present" true preflight.image_present;
      Alcotest.(check (list string)) "no failure classes" []
        preflight.failure_classes;
      Alcotest.(check (list string)) "no missing commands" []
        preflight.missing_commands

let test_docker_preflight_surfaces_missing_image_actions () =
  with_fake_docker fake_docker_preflight_missing_image_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "image missing" false preflight.image_present;
      Alcotest.(check bool) "failure class is image_missing" true
        (List.mem "image_missing" preflight.failure_classes);
      Alcotest.(check bool) "failure class is not image timeout" false
        (List.mem "image_inspect_timeout" preflight.failure_classes);
      Alcotest.(check bool) "next actions mention build script" true
        (List.exists
           (fun action ->
             String.contains action 'b'
             && contains_substring action
                  "scripts/build-keeper-sandbox-image.sh")
           preflight.next_actions);
      Alcotest.(check bool) "failure message mentions build script" true
        (contains_substring
           (Keeper_sandbox_runtime.docker_preflight_failure_message preflight)
           "scripts/build-keeper-sandbox-image.sh")

let test_docker_preflight_classifies_daemon_unavailable () =
  with_fake_docker fake_docker_preflight_daemon_unavailable_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "failure class is daemon unavailable" true
        (List.mem "docker_daemon_unavailable" preflight.failure_classes);
      Alcotest.(check bool) "not misclassified as image missing" false
        (List.mem "image_missing" preflight.failure_classes)

let test_docker_preflight_classifies_image_inspect_timeout () =
  with_fake_docker fake_docker_preflight_image_timeout_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "image absent after timeout" false preflight.image_present;
      Alcotest.(check bool) "failure class is image inspect timeout" true
        (List.mem "image_inspect_timeout" preflight.failure_classes);
      Alcotest.(check bool) "not misclassified as image missing" false
        (List.mem "image_missing" preflight.failure_classes)

let test_docker_preflight_classifies_oci_mount_failure () =
  with_fake_docker fake_docker_preflight_oci_mount_failure_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "image inspect succeeded" true preflight.image_present;
      Alcotest.(check bool) "failure class is OCI mount failure" true
        (List.mem "oci_mount_failure" preflight.failure_classes);
      Alcotest.(check bool) "not misclassified as image missing" false
        (List.mem "image_missing" preflight.failure_classes)

let test_startup_preflight_skips_required_command_inventory () =
  with_fake_docker fake_docker_startup_preflight_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  match
    Keeper_sandbox_runtime.ensure_keeper_startup_preflight
      ~timeout_sec:5.0 ~sandbox_profile:Keeper_types_profile_sandbox.Docker
  with
  | Error err -> Alcotest.failf "expected startup preflight to pass: %s" err
  | Ok () ->
    let log = read_file log_path in
    Alcotest.(check bool) "checks image presence" true
      (contains_substring log "image inspect alpine:test");
    Alcotest.(check bool) "skips docker run inventory" false
      (contains_substring log "run")

let test_run_command_nonzero_exit_errors_by_default () =
  with_fake_docker fake_docker_exit_1_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:[ "rg"; "needle"; "/home/keeper/playground/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok (_st, _out) ->
      Alcotest.fail "expected exit=1 docker command to error by default"
  | Error msg ->
      Alcotest.(check bool) "error preserves exit code" true
        (let needle = "exit=1" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_allows_configured_nonzero_exit () =
  with_fake_docker fake_docker_exit_1_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status
      ~ok_exit_codes:[ 0; 1 ] ~config ~meta
      ~command_argv:[ "rg"; "needle"; "/home/keeper/playground/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg ->
      Alcotest.failf "expected exit=1 to be allowed for rg, got %s" msg
  | Ok (st, out) ->
      Alcotest.(check (pair string int)) "preserves rg no-match status"
        ("exit", 1)
        (match st with
         | Unix.WEXITED code -> ("exit", code)
         | Unix.WSIGNALED code -> ("signaled", code)
         | Unix.WSTOPPED code -> ("stopped", code));
      Alcotest.(check string) "preserves stdout on allowed exit"
        "no matches\n" out

let test_run_command_preserves_bare_command_argv () =
  with_fake_docker fake_docker_echo_command_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:
        [ "head"; "-n"; "1"; "/home/keeper/playground/minjae/mind/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg ->
      Alcotest.failf "expected bare command argv echo, got %s" msg
  | Ok (st, out) ->
      Alcotest.(check (pair string int)) "echo script exits cleanly"
        ("exit", 0)
        (match st with
         | Unix.WEXITED code -> ("exit", code)
         | Unix.WSIGNALED code -> ("signaled", code)
         | Unix.WSTOPPED code -> ("stopped", code));
      Alcotest.(check string) "preserves bare head argv"
        "head -n 1 /home/keeper/playground/minjae/mind/demo.txt\n" out

let test_run_command_fallback_uses_docker_spawn_slot ~clock () =
  with_fake_docker fake_docker_slow_run_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let result = ref None in
  Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
          result :=
            Some
              (Keeper_sandbox_read_backend.run_command_with_status
                 ~config ~meta
                 ~command_argv:
                   [ "cat"; "/home/keeper/playground/minjae/mind/demo.txt" ]
                 ~max_bytes:4096 ~timeout_sec:5.0 ()));
      let run_started () =
        Sys.file_exists log_path
        && contains_substring (read_file log_path) "run-started"
      in
      Alcotest.(check bool)
        "fallback docker run holds Docker_spawn slot after run starts"
        true
        (wait_until ~clock ~attempts:300 (fun () ->
             run_started () && docker_spawn_in_flight () > 0)));
  (match !result with
   | None -> Alcotest.fail "expected docker read command result"
   | Some (Error msg) ->
       Alcotest.failf "expected docker read command success, got %s" msg
   | Some (Ok (st, out)) ->
       Alcotest.(check (pair string int)) "slow docker exits cleanly"
         ("exit", 0)
         (match st with
          | Unix.WEXITED code -> ("exit", code)
          | Unix.WSIGNALED code -> ("signaled", code)
          | Unix.WSTOPPED code -> ("stopped", code));
       Alcotest.(check string) "slow docker stdout" "slow ok\n" out);
   Alcotest.(check int) "Docker_spawn slot released" 0
     (docker_spawn_in_flight ())

let test_run_command_projects_keeper_secret_dir () =
  with_fake_docker fake_docker_log_run_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let secret_root =
    Filename.concat
      (Filename.concat (Filename.concat base Common.masc_dirname) "secrets")
      (Workspace_utils.safe_filename meta.name)
  in
  let token_path = Filename.concat (Filename.concat secret_root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat secret_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  ensure_dir (Filename.dirname token_path);
  ensure_dir (Filename.dirname ssh_path);
  write_file token_path "projected-token\n";
  write_file ssh_path "PRIVATE KEY";
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status
      ~config
      ~meta
      ~command_argv:[ "echo"; "hello" ]
      ~max_bytes:4096
      ~timeout_sec:5.0
      ()
  with
  | Error msg -> Alcotest.failf "expected success, got %s" msg
  | Ok (_st, _out) ->
    let line = read_file log_path in
    Alcotest.(check bool) "projected raw token not in docker argv" false
      (contains_substring line "projected-token");
    Alcotest.(check bool) "projected env uses env-file" true
      (contains_substring line "--env-file ");
    Alcotest.(check bool) "projected file mounted read-only" true
      (contains_substring line (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    (match env_file_path_from_docker_line line with
     | None -> Alcotest.fail "missing --env-file path in docker log"
     | Some env_file ->
       Alcotest.(check bool) "env-file cleaned after docker run" false
         (Sys.file_exists env_file))

let test_run_command_scrubs_sensitive_env () =
  with_fake_docker fake_docker_env_dump_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "GH_TOKEN" "ghp_secret" @@ fun () ->
  with_env "ANTHROPIC_API_KEY" "sk-ant-secret" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:[ "echo"; "hello" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg -> Alcotest.failf "expected success, got %s" msg
  | Ok (_st, _out) ->
      let env_dump_path = log_path ^ ".env" in
      let env_dump = read_file env_dump_path in
      Alcotest.(check bool) "GH_TOKEN scrubbed" false
        (contains_substring env_dump "GH_TOKEN=");
      Alcotest.(check bool) "ANTHROPIC_API_KEY scrubbed" false
        (contains_substring env_dump "ANTHROPIC_API_KEY=")

let test_turn_runtime_reuses_single_container () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_sandbox_factory.cleanup factory;
    cleanup_dir base) @@ fun () ->
  let run_once () =
    match
      Keeper_sandbox_read_backend.run_command_with_status
        ~turn_sandbox_factory:factory
        ~config ~meta
        ~command_argv:[ "cat"; "/home/keeper/playground/minjae/mind/demo.txt" ]
        ~max_bytes:4096 ~timeout_sec:5.0 ()
    with
    | Error msg -> Alcotest.failf "expected turn runtime command success, got %s" msg
    | Ok (st, out) ->
        Alcotest.(check (pair string int)) "runtime exec exits cleanly"
          ("exit", 0)
          (match st with
           | Unix.WEXITED code -> ("exit", code)
           | Unix.WSIGNALED code -> ("signaled", code)
           | Unix.WSTOPPED code -> ("stopped", code));
        Alcotest.(check string) "runtime exec output preserved" "exec ok\n" out
  in
  run_once ();
  run_once ();
  Keeper_sandbox_factory.cleanup factory;
  let lines =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let count prefix =
    List.fold_left
      (fun acc line ->
        if String.starts_with ~prefix line then acc + 1 else acc)
      0 lines
  in
  Alcotest.(check int) "docker run happens once" 1 (count "run -d ");
  Alcotest.(check int) "docker exec happens twice" 2 (count "exec ");
  Alcotest.(check int) "docker rm happens once" 1 (count "rm -f ");
  let container_root = Keeper_sandbox.container_root meta.name in
  let container_config_dir =
    Keeper_sandbox_runtime.container_masc_config_dir ~container_root
  in
  let run_line =
    lines
    |> List.find_opt (fun line -> String.starts_with ~prefix:"run -d " line)
    |> Option.value ~default:""
  in
  let exec_line =
    lines
    |> List.find_opt (fun line -> String.starts_with ~prefix:"exec " line)
    |> Option.value ~default:""
  in
  Alcotest.(check bool) "turn run mounts config read-only" true
    (contains_substring
       run_line
       (host_config_dir ^ ":" ^ container_config_dir ^ ":ro"));
  Alcotest.(check bool) "turn run pins MASC_CONFIG_DIR" true
    (contains_substring run_line ("MASC_CONFIG_DIR=" ^ container_config_dir));
  Alcotest.(check bool) "turn exec pins MASC_CONFIG_DIR" true
    (contains_substring exec_line ("MASC_CONFIG_DIR=" ^ container_config_dir))

let test_streaming_exec_validates_cached_container_before_retry () =
  with_fake_docker fake_docker_stale_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  let inspect_count_path = Filename.concat base "inspect.count" in
  let exec_count_path = Filename.concat base "exec.count" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "KEEPER_DOCKER_INSPECT_COUNT" inspect_count_path @@ fun () ->
  with_env "KEEPER_DOCKER_EXEC_COUNT" exec_count_path @@ fun () ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/second" ]
   with
   | Error msg -> Alcotest.failf "expected retried exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "retried exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected retried exec exit 0");
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check bool)
    "stale container error is not streamed"
    false
    (contains_substring streamed_stderr "synthetic opaque state inspection failure")

let test_streaming_exec_preserves_split_stderr () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  match
    Keeper_turn_sandbox_runtime.run_exec_with_status_split
      ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
      ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
      ~timeout_sec:5.0
      runtime
      ~cwd:host_root
      ~command_argv:[ "stderr-only" ]
  with
  | Error msg -> Alcotest.failf "expected split exec result, got %s" msg
  | Ok (Unix.WEXITED 7, stdout, stderr) ->
      Alcotest.(check string) "split stdout stays empty" "" stdout;
      Alcotest.(check string) "split stderr is preserved" "only stderr\n" stderr;
      Alcotest.(check string)
        "stdout callback stays empty"
        ""
        (String.concat "" (List.rev !stdout_chunks));
      Alcotest.(check string)
        "stderr callback receives stderr"
        "only stderr\n"
      (String.concat "" (List.rev !stderr_chunks))
  | Ok _ -> Alcotest.fail "expected stderr-only exec exit 7"

let test_streaming_exec_forwards_timeout_to_split_exec () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~timeout_sec:0.2
       runtime
       ~cwd:host_root
       ~command_argv:[ "slow-timeout" ]
   with
   | Error msg -> Alcotest.failf "expected split timeout result, got %s" msg
   | Ok (Unix.WEXITED 124, stdout, stderr) ->
       Alcotest.(check string) "timeout stdout" "" stdout;
       Alcotest.(check bool)
         "timeout stderr surfaced"
         true
         (contains_substring stderr "timeout after")
   | Ok _ -> Alcotest.fail "expected split exec timeout exit 124");
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check bool)
    "split exec timeout uses caller budget"
    true
    (elapsed < 1.5)

let test_streaming_pipeline_forwards_timeout_to_split_exec () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let stdout_chunks = ref [] in
  let start = Unix.gettimeofday () in
  (match
     Keeper_turn_sandbox_runtime.run_exec_pipeline_with_status
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~timeout_sec:0.2
       runtime
       ~cwd:host_root
       ~stages:
         [ { Keeper_turn_sandbox_runtime.command_argv = [ "slow-timeout" ]
           ; cwd = None
           }
         ; { command_argv = [ "slow-timeout" ]; cwd = None }
         ]
   with
   | Error msg -> Alcotest.failf "expected pipeline timeout result, got %s" msg
   | Ok (Unix.WEXITED 124, stdout, stderr) ->
       Alcotest.(check string) "pipeline timeout stdout" "" stdout;
       Alcotest.(check bool)
         "pipeline timeout stderr surfaced"
         true
         (contains_substring stderr "timeout after")
   | Ok _ -> Alcotest.fail "expected pipeline timeout exit 124");
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check string)
    "pipeline timeout callback stdout"
    ""
    (String.concat "" (List.rev !stdout_chunks));
  Alcotest.(check bool)
    "split pipeline timeout uses caller budget"
    true
    (elapsed < 1.5)

let test_streaming_exec_restarts_stopped_container_before_exec () =
  with_fake_docker fake_docker_stopped_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/second" ]
   with
   | Error msg -> Alcotest.failf "expected restarted exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "restarted exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected restarted exec exit 0");
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check bool)
    "stopped container error is not streamed"
    false
    (contains_substring streamed_stderr "synthetic opaque stopped-container exec failure")

let test_streaming_exec_buffers_eintr_retry_output () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/second" ]
   with
   | Error msg -> Alcotest.failf "expected retried exec success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string) "retried stdout" "exec ok\n" stdout;
       Alcotest.(check string) "retried stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected retried exec exit 0");
  let streamed_stdout = String.concat "" (List.rev !stdout_chunks) in
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check string) "callback stdout" "exec ok\n" streamed_stdout;
  Alcotest.(check string) "callback stderr" "" streamed_stderr;
  Alcotest.(check bool)
    "retry-only stdout is not streamed"
    false
    (contains_substring streamed_stdout "retry-only stdout");
  Alcotest.(check bool)
    "retry-only stderr is not streamed"
    false
    (contains_substring streamed_stderr "interrupted system call")

let test_streaming_exec_keeps_successful_progress_live () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk ->
         if Option.is_none !first_stdout_at
         then first_stdout_at := Some (Unix.gettimeofday () -. start);
         stdout_chunks := chunk :: !stdout_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "progress" ]
   with
   | Error msg -> Alcotest.failf "expected progress exec success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string)
         "progress stdout"
         "progress-1\nprogress-2\ndone\n"
         stdout;
       Alcotest.(check string) "progress stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected progress exec exit 0");
  let elapsed = Unix.gettimeofday () -. start in
  let first_stdout_at =
    match !first_stdout_at with
    | Some at -> at
    | None -> Alcotest.fail "expected progress stdout callback"
  in
  Alcotest.(check string)
    "progress callback stdout"
    "progress-1\nprogress-2\ndone\n"
    (String.concat "" (List.rev !stdout_chunks));
  Alcotest.(check bool)
    "progress callback arrives before command completion"
    true
    (first_stdout_at < elapsed -. 0.5)

let test_streaming_exec_keeps_sparse_progress_live () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  let first_stdout_at = Atomic.make None in
  let callback_on_turn_switch = ref [] in
  let stdout_chunks = ref [] in
  let stdout_mu = Stdlib.Mutex.create () in
  Eio.Switch.run (fun turn_sw ->
    Eio_context.with_turn_switch turn_sw (fun () ->
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status_split
          ~on_stdout_chunk:(fun chunk ->
            if Option.is_none (Atomic.get first_stdout_at)
            then Atomic.set first_stdout_at (Some (Unix.gettimeofday () -. start));
            let saw_turn_switch =
              match Eio_context.get_switch_opt () with
              | Some sw -> sw == turn_sw
              | None -> false
            in
            Stdlib.Mutex.protect stdout_mu (fun () ->
              callback_on_turn_switch := saw_turn_switch :: !callback_on_turn_switch;
              stdout_chunks := chunk :: !stdout_chunks))
          ~timeout_sec:5.0
          runtime
          ~cwd:host_root
          ~command_argv:[ "sparse-progress" ]
      with
      | Error msg ->
        Alcotest.failf "expected sparse progress exec success, got %s" msg
      | Ok (Unix.WEXITED 0, stdout, stderr) ->
        Alcotest.(check string) "sparse progress stdout" "ready\ndone\n" stdout;
        Alcotest.(check string) "sparse progress stderr" "" stderr
      | Ok _ -> Alcotest.fail "expected sparse progress exec exit 0"));
  let elapsed = Unix.gettimeofday () -. start in
  let first_stdout_at =
    match Atomic.get first_stdout_at with
    | Some at -> at
    | None -> Alcotest.fail "expected sparse progress stdout callback"
  in
  let streamed_stdout =
    Stdlib.Mutex.protect stdout_mu (fun () ->
      String.concat "" (List.rev !stdout_chunks))
  in
  let callback_on_turn_switch =
    Stdlib.Mutex.protect stdout_mu (fun () -> List.rev !callback_on_turn_switch)
  in
  Alcotest.(check string)
    "sparse progress callback stdout"
    "ready\ndone\n"
    streamed_stdout;
  Alcotest.(check bool)
    "sparse progress callback keeps turn switch"
    true
    (List.for_all Fun.id callback_on_turn_switch);
  Alcotest.(check bool)
    "single sparse progress callback arrives before command completion"
    true
    (first_stdout_at < elapsed -. 0.2)

let test_streaming_exec_releases_retry_marker_prefix_progress () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  let first_stdout_at = Atomic.make None in
  let stdout_chunks = ref [] in
  let stdout_mu = Stdlib.Mutex.create () in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk ->
         if Option.is_none (Atomic.get first_stdout_at)
         then Atomic.set first_stdout_at (Some (Unix.gettimeofday () -. start));
         Stdlib.Mutex.protect stdout_mu (fun () ->
           stdout_chunks := chunk :: !stdout_chunks))
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "marker-prefix-progress" ]
   with
   | Error msg ->
       Alcotest.failf "expected marker-prefix progress exec success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string)
         "marker-prefix progress stdout"
         "interdone\n"
         stdout;
       Alcotest.(check string) "marker-prefix progress stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected marker-prefix progress exec exit 0");
  let elapsed = Unix.gettimeofday () -. start in
  let first_stdout_at =
    match Atomic.get first_stdout_at with
    | Some at -> at
    | None -> Alcotest.fail "expected marker-prefix progress stdout callback"
  in
  let streamed_stdout =
    Stdlib.Mutex.protect stdout_mu (fun () ->
      String.concat "" (List.rev !stdout_chunks))
  in
  Alcotest.(check string)
    "marker-prefix progress callback stdout"
    "interdone\n"
    streamed_stdout;
  Alcotest.(check bool)
    "retry-marker prefix callback arrives before command returns"
    true
    (first_stdout_at < elapsed)

let test_streaming_exec_retries_split_eintr_marker_without_leak () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "split-eintr" ]
   with
   | Error msg -> Alcotest.failf "expected split marker retry success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string) "split marker retried stdout" "exec ok\n" stdout;
       Alcotest.(check string) "split marker retried stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected split marker retry exit 0");
  let streamed_stdout = String.concat "" (List.rev !stdout_chunks) in
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check string) "split marker callback stdout" "exec ok\n" streamed_stdout;
  Alcotest.(check string) "split marker callback stderr" "" streamed_stderr;
  Alcotest.(check bool)
    "split marker retry-only stdout is not streamed"
    false
    (contains_substring streamed_stdout "retry-only stdout");
  Alcotest.(check bool)
    "split marker retry-only stderr is not streamed"
    false
    (contains_substring streamed_stderr "interrupted system call")

let test_streaming_exec_retries_after_visible_progress () =
  with_fake_docker fake_docker_eintr_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "early-eintr" ]
   with
   | Error msg -> Alcotest.failf "expected visible-progress retry success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string) "visible-progress retried stdout" "exec ok\n" stdout;
       Alcotest.(check string) "visible-progress retried stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected visible-progress retry exit 0");
  let streamed_stdout = String.concat "" (List.rev !stdout_chunks) in
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check bool)
    "early visible progress stays streamed"
    true
    (contains_substring streamed_stdout "early-progress\n");
  Alcotest.(check bool)
    "retried stdout is streamed"
    true
    (contains_substring streamed_stdout "exec ok\n");
  Alcotest.(check bool)
    "visible-progress retry stderr is not streamed"
    false
    (contains_substring streamed_stderr "interrupted system call")

let test_default_fs_hardening_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "false" @@ fun () ->
  Alcotest.(check (list string)) "default helper keeps read-only rootfs"
    [ "--read-only" ]
    (Env_config_sandbox.Hardening.read_only_rootfs_args ());
  Alcotest.(check bool) "default helper keeps tmpfs noexec" true
    (contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=")

let test_relaxed_fs_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  Alcotest.(check (list string)) "relaxed helper drops read-only rootfs"
    [] (Env_config_sandbox.Hardening.read_only_rootfs_args ());
  Alcotest.(check bool) "relaxed helper drops tmpfs noexec" false
    (contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=");
  Alcotest.(check bool) "relaxed helper keeps writable tmpfs mount" true
    (contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,size=")

let test_turn_runtime_relaxed_fs_omits_readonly_and_noexec () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir host_root;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_sandbox_factory.cleanup factory;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_sandbox_read_backend.run_command_with_status
       ~turn_sandbox_factory:factory
       ~config ~meta
       ~command_argv:[ "cat"; "/home/keeper/playground/minjae/mind/demo.txt" ]
       ~max_bytes:4096 ~timeout_sec:5.0 ()
   with
   | Error msg -> Alcotest.failf "expected turn runtime command success, got %s" msg
   | Ok _ -> ());
  Keeper_sandbox_factory.cleanup factory;
  let run_line =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.starts_with ~prefix:"run -d " line)
  in
  match run_line with
  | None -> Alcotest.fail "expected docker run log line"
  | Some line ->
      Alcotest.(check bool) "relaxed runtime drops read-only rootfs" false
        (contains_substring line "--read-only");
      Alcotest.(check bool) "relaxed runtime drops tmpfs noexec" false
        (contains_substring line "/tmp:rw,nosuid,nodev,noexec,size=");
      Alcotest.(check bool) "relaxed runtime keeps tmpfs mount" true
        (contains_substring line "/tmp:rw,nosuid,nodev,size=")

let run_tests ~clock () =
  Alcotest.run "Keeper_sandbox_read_backend"
    [
      ( "should_route_read",
        [
          Alcotest.test_case "legacy never routes" `Quick
            test_legacy_keeper_never_routes;
          Alcotest.test_case "docker keeper routes" `Quick
            test_docker_keeper_routes;
          Alcotest.test_case "docker second keeper also routes" `Quick
            test_docker_second_keeper_routes;
        ] );
      ( "container_path_of_host",
        [
          Alcotest.test_case "docker network args follow policy" `Quick
            test_docker_network_args_follow_masc_policy;
          Alcotest.test_case "docker nofile args follow config" `Quick
            test_docker_nofile_args_follow_config;
          Alcotest.test_case "docker MASC config binding pins paths" `Quick
            test_docker_masc_config_binding_pins_container_runtime_paths;
          Alcotest.test_case "docker config mount and env args" `Quick
            test_docker_config_mount_and_env_args;
          Alcotest.test_case "docker run timeout is terminal" `Quick
            test_docker_run_looks_daemon_pressure_does_not_retry_timeout;
          Alcotest.test_case "docker run classifies daemon unavailable as pressure" `Quick
            test_docker_run_looks_daemon_pressure_classifies_daemon_unavailable;
          Alcotest.test_case "docker run does not classify command error as pressure" `Quick
            test_docker_run_looks_daemon_pressure_not_pressure_on_command_error;
          Alcotest.test_case "docker run does not classify connection refused as pressure" `Quick
            test_docker_run_looks_daemon_pressure_not_pressure_on_connection_refused;
          Alcotest.test_case "docker failure class is typed and serializes stable string" `Quick
            test_docker_failure_class_is_typed_and_serializes_stable_string;
          Alcotest.test_case "docker workspace state mount exposes safe subset" `Quick
            test_docker_workspace_state_mount_args_expose_safe_subset;
          Alcotest.test_case "oneshot label args include ttl" `Quick
            test_sandbox_container_label_args_include_oneshot_ttl;
          Alcotest.test_case "sandbox label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
          Alcotest.test_case "relative base hash anchors to cwd" `Quick
            test_base_path_hash_relative_input_anchors_to_cwd_not_env_base;
          Alcotest.test_case "playground root maps to container root"
            `Quick test_container_path_root_maps;
          Alcotest.test_case "nested host path maps with suffix" `Quick
            test_container_path_nested_maps_with_suffix;
          Alcotest.test_case "outside playground errors" `Quick
            test_container_path_outside_playground_errors;
        ] );
      ( "read_file",
        [
          Alcotest.test_case "outside playground returns mapping error"
            `Quick test_read_outside_playground_returns_mapping_error;
          Alcotest.test_case "missing file preflight errors" `Quick
            test_read_missing_file_preflight_errors;
          Alcotest.test_case "directory read names a real listing tool" `Quick
            test_read_directory_names_a_real_listing_tool;
        ] );
      ( "run_command",
        [
          Alcotest.test_case "empty command_argv errors" `Quick
            test_run_command_empty_argv_errors;
          Alcotest.test_case "empty image configuration errors" `Quick
            test_run_command_empty_image_errors;
          Alcotest.test_case "nonzero exit errors by default" `Quick
            test_run_command_nonzero_exit_errors_by_default;
          Alcotest.test_case "configured nonzero exit is allowed" `Quick
            test_run_command_allows_configured_nonzero_exit;
          Alcotest.test_case "preserves bare command argv" `Quick
            test_run_command_preserves_bare_command_argv;
          Alcotest.test_case "fallback uses Docker_spawn slot" `Quick
            (test_run_command_fallback_uses_docker_spawn_slot ~clock);
          Alcotest.test_case "projects keeper secret directory" `Quick
            test_run_command_projects_keeper_secret_dir;
          Alcotest.test_case "default fs hardening helpers" `Quick
            test_default_fs_hardening_helpers;
          Alcotest.test_case "relaxed fs helpers" `Quick
            test_relaxed_fs_helpers;
          Alcotest.test_case "turn runtime reuses single container" `Quick
            test_turn_runtime_reuses_single_container;
          Alcotest.test_case
            "streaming exec validates cached container before retry"
            `Quick test_streaming_exec_validates_cached_container_before_retry;
          Alcotest.test_case
            "streaming exec preserves split stderr"
            `Quick test_streaming_exec_preserves_split_stderr;
          Alcotest.test_case
            "streaming exec forwards timeout to split exec"
            `Quick test_streaming_exec_forwards_timeout_to_split_exec;
          Alcotest.test_case
            "streaming pipeline forwards timeout to split exec"
            `Quick test_streaming_pipeline_forwards_timeout_to_split_exec;
          Alcotest.test_case
            "streaming exec restarts stopped container before exec"
            `Quick test_streaming_exec_restarts_stopped_container_before_exec;
          Alcotest.test_case
            "streaming exec buffers EINTR retry output"
            `Quick test_streaming_exec_buffers_eintr_retry_output;
          Alcotest.test_case
            "streaming exec keeps successful progress live"
            `Quick test_streaming_exec_keeps_successful_progress_live;
          Alcotest.test_case
            "streaming exec keeps sparse progress live"
            `Quick test_streaming_exec_keeps_sparse_progress_live;
          Alcotest.test_case
            "streaming exec releases retry-marker prefix progress"
            `Quick test_streaming_exec_releases_retry_marker_prefix_progress;
          Alcotest.test_case
            "streaming exec retries split EINTR marker without leak"
            `Quick test_streaming_exec_retries_split_eintr_marker_without_leak;
          Alcotest.test_case
            "streaming exec retries after visible progress"
            `Quick test_streaming_exec_retries_after_visible_progress;
          Alcotest.test_case
            "turn runtime relaxed fs omits readonly and noexec"
            `Quick test_turn_runtime_relaxed_fs_omits_readonly_and_noexec;
        ] );
      ( "docker_preflight",
        [
          Alcotest.test_case "ready image reports ok" `Quick
            test_docker_preflight_reports_ready_image;
          Alcotest.test_case "missing image surfaces remediation" `Quick
            test_docker_preflight_surfaces_missing_image_actions;
          Alcotest.test_case "daemon unavailable has distinct failure class" `Quick
            test_docker_preflight_classifies_daemon_unavailable;
          Alcotest.test_case "image inspect timeout has distinct failure class" `Quick
            test_docker_preflight_classifies_image_inspect_timeout;
          Alcotest.test_case "OCI mount failure has distinct failure class" `Quick
            test_docker_preflight_classifies_oci_mount_failure;
          Alcotest.test_case "startup skips command inventory" `Quick
            test_startup_preflight_skips_required_command_inventory;
        ] );
      ( "docker_cleanup",
        [
          Alcotest.test_case "label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
          Alcotest.test_case "cleanup removes stale scoped containers" `Quick
            test_cleanup_stale_containers_removes_only_stale_masc_scope;
          Alcotest.test_case "cleanup accepts concurrent disappearance" `Quick
            test_cleanup_stale_containers_accepts_concurrent_disappearance;
          Alcotest.test_case "cleanup preserves failure for present container" `Quick
            test_cleanup_stale_containers_preserves_present_failure;
          Alcotest.test_case "cleanup disappearance does not back off" `Quick
            test_maybe_cleanup_disappearance_does_not_activate_backoff;
          Alcotest.test_case "cleanup CAS runs once per interval" `Quick
            test_maybe_cleanup_stale_containers_runs_once_per_interval;
          Alcotest.test_case "cleanup failure activates backoff" `Quick
            test_maybe_cleanup_stale_containers_backs_off_after_failure;
        ] );
    ]

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
  run_tests ~clock ()
