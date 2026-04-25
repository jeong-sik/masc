(** Tests for Keeper_docker_read.

    RFC-0006 Phase B-2: docker-routed reads for Docker keepers.
    These tests cover the pure path-mapping and routing logic;
    the actual [docker run] call is exercised only in environments
    where docker is available, gated through env-set integration
    tests. *)

module Coord = Masc_mcp.Coord
module Keeper_docker_read = Masc_mcp.Keeper_docker_read
module Keeper_turn_sandbox_runtime = Masc_mcp.Keeper_turn_sandbox_runtime
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_sandbox_runtime = Masc_mcp.Keeper_sandbox_runtime
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
  let d = Filename.temp_file "keeper_docker_read_" "" in
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
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

(* ── should_route_read profile policy ────────────────────────────── *)

let test_legacy_keeper_never_routes () =
  let meta = make_meta ~name:"alice" ~sandbox:Keeper_types.Local in
  Alcotest.(check bool) "legacy keeper never routes through docker"
    false
    (Keeper_docker_read.should_route_read ~meta)

let test_docker_keeper_routes () =
  let meta =
    make_meta ~name:"minjae" ~sandbox:Keeper_types.Docker
  in
  Alcotest.(check bool) "docker keeper routes through docker"
    true
    (Keeper_docker_read.should_route_read ~meta)

let test_docker_git_creds_routes () =
  let meta =
    make_meta ~name:"poe" ~sandbox:Keeper_types.Docker
  in
  Alcotest.(check bool) "docker git-creds also routes" true
    (Keeper_docker_read.should_route_read ~meta)

(* ── container_path_of_host pure mapping ─────────────────────────── *)

let setup_config name =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base Common.masc_dirname) 0o755;
  let config = Coord.default_config base in
  let meta =
    make_meta ~name ~sandbox:Keeper_types.Docker
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
    Keeper_docker_read.container_path_of_host ~config ~meta
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
    Keeper_docker_read.container_path_of_host ~config ~meta ~host_path
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
    Keeper_docker_read.container_path_of_host ~config ~meta
      ~host_path:outside
  with
  | Ok mapped ->
      Alcotest.failf
        "expected error for outside-playground path, got Ok %s" mapped
  | Error _ -> ()

(* ── Integration: read_file_in_container error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_read_outside_playground_returns_mapping_error () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_docker_read.read_file_in_container ~config ~meta
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

let test_read_empty_image_config_errors () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_path = Filename.concat host_root "mind/x" in
  match
    Keeper_docker_read.read_file_in_container ~config ~meta ~host_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected image-config error"
  | Error msg ->
      Alcotest.(check bool) "error mentions docker image" true
        (let needle = "docker image" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

(* ── run_command_in_container error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_run_command_empty_argv_errors () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_docker_read.run_command_in_container ~config ~meta
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
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_docker_read.run_command_in_container ~config ~meta
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

let fake_docker_turn_runtime_script =
  "#!/bin/sh\n\
log_file=${KEEPER_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
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

let fake_docker_cleanup_script =
  "#!/bin/sh\n\
log_file=${KEEPER_DOCKER_LOG:-}\n\
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
    if [ \"$2\" = \"-f\" ] && [ \"$3\" = \"old-container\" ]; then\n\
      printf 'old-container\\n'\n\
      exit 0\n\
    fi\n\
    printf 'unexpected rm target\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let test_sandbox_container_label_args_include_owner_scope () =
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~base_path:"/tmp/masc"
      ~keeper_name:"min/jae"
      ~container_kind:"turn"
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

let test_sandbox_container_label_args_include_managed_ttl () =
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~ttl_sec:90.0
      ~base_path:"/tmp/masc"
      ~keeper_name:"issue-king"
      ~container_kind:"managed"
      ~network_label:"inherit" ()
  in
  let has_label value = List.mem value args in
  Alcotest.(check bool) "managed kind label" true
    (has_label "masc.mcp.kind=managed");
  Alcotest.(check bool) "ttl label" true
    (has_label "masc.mcp.ttl_sec=90");
  Alcotest.(check bool) "inherit network label" true
    (has_label "masc.mcp.network=inherit")

let test_docker_network_args_follow_masc_policy () =
  let args_none, label_none =
    Keeper_sandbox_runtime.docker_network_args Keeper_types.Network_none
  in
  Alcotest.(check (list string)) "network none passes docker flag"
    [ "--network"; "none" ] args_none;
  Alcotest.(check string) "network none label" "none" label_none;
  let args_inherit, label_inherit =
    Keeper_sandbox_runtime.docker_network_args Keeper_types.Network_inherit
  in
  Alcotest.(check (list string)) "network inherit omits docker flag"
    [] args_inherit;
  Alcotest.(check string) "network inherit label" "inherit" label_inherit

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

let test_cleanup_stale_containers_removes_only_stale_masc_scope () =
  with_fake_docker fake_docker_cleanup_script @@ fun () ->
  let base = temp_dir () in
  let log_path = Filename.concat base "docker.log" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
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
  Alcotest.(check (list string)) "no cleanup errors" [] result.errors;
  let log = read_file log_path in
  Alcotest.(check bool) "removes old container" true
    (contains_substring log "rm -f old-container");
  Alcotest.(check bool) "keeps fresh container" false
    (contains_substring log "rm -f fresh-container")

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

let test_run_command_nonzero_exit_errors_by_default () =
  with_fake_docker fake_docker_exit_1_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_docker_read.run_command_in_container_with_status ~config ~meta
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
    Keeper_docker_read.run_command_in_container_with_status
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
    Keeper_docker_read.run_command_in_container_with_status ~config ~meta
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

let test_turn_runtime_reuses_single_container () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  let log_path = Filename.concat base "docker.log" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir host_root;
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let run_once () =
    match
      Keeper_docker_read.run_command_in_container_with_status
        ~turn_sandbox_runtime:runtime
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
  Keeper_turn_sandbox_runtime.cleanup runtime;
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
  Alcotest.(check int) "docker rm happens once" 1 (count "rm -f ")

let test_default_fs_hardening_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "false" @@ fun () ->
  Alcotest.(check (list string)) "default helper keeps read-only rootfs"
    [ "--read-only" ]
    (Env_config_keeper.KeeperSandbox.read_only_rootfs_args ());
  Alcotest.(check bool) "default helper keeps tmpfs noexec" true
    (contains_substring
       (Env_config_keeper.KeeperSandbox.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=")

let test_relaxed_fs_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  Alcotest.(check (list string)) "relaxed helper drops read-only rootfs"
    [] (Env_config_keeper.KeeperSandbox.read_only_rootfs_args ());
  Alcotest.(check bool) "relaxed helper drops tmpfs noexec" false
    (contains_substring
       (Env_config_keeper.KeeperSandbox.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=");
  Alcotest.(check bool) "relaxed helper keeps writable tmpfs mount" true
    (contains_substring
       (Env_config_keeper.KeeperSandbox.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,size=")

let test_hard_mode_forces_policy_helpers () =
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_GIT_DISPATCH" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_GH_CREDS" "/tmp/host-gh" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_GITCONFIG" "/tmp/host-gitconfig" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SSH_DIR" "/tmp/host-ssh" @@ fun () ->
  with_env "GH_TOKEN" "host-token" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "explicit-token" @@ fun () ->
  Alcotest.(check bool) "hard mode forces rootless" true
    (Env_config_keeper.KeeperSandbox.require_rootless ());
  Alcotest.(check bool) "hard mode forces userns" true
    (Env_config_keeper.KeeperSandbox.require_userns ());
  Alcotest.(check bool) "hard mode disables docker git dispatch" false
    (Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled ());
  Alcotest.(check string) "hard mode drops gh config mount" ""
    (Env_config_keeper.KeeperSandbox.gh_creds_host_path ());
  Alcotest.(check string) "hard mode drops gitconfig mount" ""
    (Env_config_keeper.KeeperSandbox.gitconfig_host_path ());
  Alcotest.(check string) "hard mode drops ssh mount" ""
    (Env_config_keeper.KeeperSandbox.ssh_dir_host_path ());
  Alcotest.(check string) "hard mode drops GH_TOKEN forwarding" ""
    (Env_config_keeper.KeeperSandbox.gh_token ())

let test_gh_token_prefers_explicit_override () =
  let calls = ref 0 in
  Env_config_keeper.KeeperSandbox.For_testing.with_gh_token_probe
    (fun () ->
      incr calls;
      Some "probe-token")
    (fun () ->
      with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "" @@ fun () ->
      with_env "GH_TOKEN" "host-token" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "explicit-token" @@ fun () ->
      Alcotest.(check string) "explicit override wins" "explicit-token"
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check int) "probe not called" 0 !calls)

let test_gh_token_prefers_host_env_over_keychain_probe () =
  let calls = ref 0 in
  Env_config_keeper.KeeperSandbox.For_testing.with_gh_token_probe
    (fun () ->
      incr calls;
      Some "probe-token")
    (fun () ->
      with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "" @@ fun () ->
      with_env "GH_TOKEN" "host-token" @@ fun () ->
      Alcotest.(check string) "host GH_TOKEN wins" "host-token"
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check int) "probe not called" 0 !calls)

let test_gh_token_uses_cached_keychain_probe () =
  let calls = ref 0 in
  Env_config_keeper.KeeperSandbox.For_testing.with_gh_token_probe
    (fun () ->
      incr calls;
      Some "  probe-token\n")
    (fun () ->
      with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "" @@ fun () ->
      with_env "GH_TOKEN" "" @@ fun () ->
      Alcotest.(check string) "keychain fallback token" "probe-token"
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check string) "cached keychain fallback" "probe-token"
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check int) "probe called once" 1 !calls)

let test_gh_token_caches_empty_keychain_probe () =
  let calls = ref 0 in
  Env_config_keeper.KeeperSandbox.For_testing.with_gh_token_probe
    (fun () ->
      incr calls;
      None)
    (fun () ->
      with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "" @@ fun () ->
      with_env "GH_TOKEN" "" @@ fun () ->
      Alcotest.(check string) "empty keychain fallback" ""
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check string) "cached empty keychain fallback" ""
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check int) "probe called once" 1 !calls)

let test_gh_token_hard_mode_skips_keychain_probe () =
  let calls = ref 0 in
  Env_config_keeper.KeeperSandbox.For_testing.with_gh_token_probe
    (fun () ->
      incr calls;
      Some "probe-token")
    (fun () ->
      with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_GH_TOKEN" "explicit-token" @@ fun () ->
      with_env "GH_TOKEN" "host-token" @@ fun () ->
      Alcotest.(check string) "hard mode drops token" ""
        (Env_config_keeper.KeeperSandbox.gh_token ());
      Alcotest.(check int) "probe not called" 0 !calls)

let test_hard_mode_rejects_relaxed_fs_without_docker () =
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec:5.0 with
  | Ok _ -> Alcotest.fail "expected hard mode to reject RELAX_FS"
  | Error msg ->
      Alcotest.(check string) "hard mode relax fs error"
        "sandbox hard mode requires MASC_KEEPER_SANDBOX_RELAX_FS=false"
        msg

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
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_docker_read.run_command_in_container_with_status
       ~turn_sandbox_runtime:runtime
       ~config ~meta
       ~command_argv:[ "cat"; "/home/keeper/playground/minjae/mind/demo.txt" ]
       ~max_bytes:4096 ~timeout_sec:5.0 ()
   with
   | Error msg -> Alcotest.failf "expected turn runtime command success, got %s" msg
   | Ok _ -> ());
  Keeper_turn_sandbox_runtime.cleanup runtime;
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

let run_tests () =
  Alcotest.run "Keeper_docker_read"
    [
      ( "should_route_read",
        [
          Alcotest.test_case "legacy never routes" `Quick
            test_legacy_keeper_never_routes;
          Alcotest.test_case "docker keeper routes" `Quick
            test_docker_keeper_routes;
          Alcotest.test_case "docker git-creds also routes" `Quick
            test_docker_git_creds_routes;
        ] );
      ( "container_path_of_host",
        [
          Alcotest.test_case "docker network args follow policy" `Quick
            test_docker_network_args_follow_masc_policy;
          Alcotest.test_case "docker nofile args follow config" `Quick
            test_docker_nofile_args_follow_config;
          Alcotest.test_case "managed label args include ttl" `Quick
            test_sandbox_container_label_args_include_managed_ttl;
          Alcotest.test_case "sandbox label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
          Alcotest.test_case "playground root maps to container root"
            `Quick test_container_path_root_maps;
          Alcotest.test_case "nested host path maps with suffix" `Quick
            test_container_path_nested_maps_with_suffix;
          Alcotest.test_case "outside playground errors" `Quick
            test_container_path_outside_playground_errors;
        ] );
      ( "read_file_in_container",
        [
          Alcotest.test_case "outside playground returns mapping error"
            `Quick test_read_outside_playground_returns_mapping_error;
          Alcotest.test_case "empty image configuration errors" `Quick
            test_read_empty_image_config_errors;
        ] );
      ( "run_command_in_container",
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
          Alcotest.test_case "default fs hardening helpers" `Quick
            test_default_fs_hardening_helpers;
          Alcotest.test_case "relaxed fs helpers" `Quick
            test_relaxed_fs_helpers;
          Alcotest.test_case "hard mode forces policy helpers" `Quick
            test_hard_mode_forces_policy_helpers;
          Alcotest.test_case "GH_TOKEN explicit override wins" `Quick
            test_gh_token_prefers_explicit_override;
          Alcotest.test_case "GH_TOKEN host env wins before keychain" `Quick
            test_gh_token_prefers_host_env_over_keychain_probe;
          Alcotest.test_case "GH_TOKEN keychain probe is cached" `Quick
            test_gh_token_uses_cached_keychain_probe;
          Alcotest.test_case "GH_TOKEN empty keychain probe is cached"
            `Quick test_gh_token_caches_empty_keychain_probe;
          Alcotest.test_case "GH_TOKEN hard mode skips keychain probe"
            `Quick test_gh_token_hard_mode_skips_keychain_probe;
          Alcotest.test_case "hard mode rejects relaxed fs without docker"
            `Quick test_hard_mode_rejects_relaxed_fs_without_docker;
          Alcotest.test_case "turn runtime reuses single container" `Quick
            test_turn_runtime_reuses_single_container;
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
        ] );
      ( "docker_cleanup",
        [
          Alcotest.test_case "label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
          Alcotest.test_case "cleanup removes stale scoped containers" `Quick
            test_cleanup_stale_containers_removes_only_stale_masc_scope;
        ] );
    ]

let () =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  run_tests ()
