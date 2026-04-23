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
  Unix.mkdir (Filename.concat base ".masc") 0o755;
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

let () =
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
    ]
