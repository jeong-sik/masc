open Alcotest

(* [validate-runtime-config] is what the deployment gate runs on the
   runtime.toml a workspace's server reads (#39311). Each case runs the built
   helper on a throwaway BasePath, as the gate does. The variables that move
   the config root, the seeding and the model catalog are cleared for every
   case, so the file under that BasePath is the one read. *)

let read path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

(* [cwd] is where the helper starts, for a relative BasePath. The output files
   go under [root]. *)
let run_exe ?cwd exe root args =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let output = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let errors = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let exe = absolute exe in
  let previous_cwd = Sys.getcwd () in
  let status = Fun.protect
    ~finally:(fun () -> Sys.chdir previous_cwd; Unix.close output; Unix.close errors)
    (fun () ->
      Option.iter Sys.chdir cwd;
      let pid = Unix.create_process exe (Array.of_list (exe :: args)) Unix.stdin output errors in
      snd (Unix.waitpid [] pid)) in
  status, read stdout_path ^ read stderr_path

let invoke ?cwd exe root argument extra =
  run_exe ?cwd exe root ("validate-runtime-config" :: "--base-path" :: argument :: extra)

let run_helper exe root extra = invoke exe root root extra

let with_env pairs f =
  List.fold_right
    (fun (key, value) f () -> Masc_test_deps.with_process_env key value f)
    pairs f ()

let lease_root root = Filename.concat root "lease-root"

let with_workspace f =
  let root = Filename.temp_dir "preflight-runtime-config-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Unix.mkdir (lease_root root) 0o700;
    with_env
      [ "MASC_CONFIG_DIR", None
      ; "MASC_CONFIG_BOOTSTRAP", None
      ; "AGENT_CORE_MODEL_CATALOG", None
      ; "MASC_BASE_PATH_LEASE_DIR", Some (lease_root root) ]
      (fun () -> f root))

let write_runtime_config root text =
  let config = Filename.concat root ".masc/config" in
  Fs_compat.mkdir_p config;
  write (Filename.concat config "runtime.toml") text

let seed () = read (Sys.getenv "MASC_TEST_RUNTIME_SEED")

let reports output expected =
  check bool ("reports " ^ expected ^ ": " ^ output) true
    (String_util.contains_substring output expected)

let passes label (status, output) =
  check bool (label ^ ": " ^ output) true (status = Unix.WEXITED 0);
  output

let refuses label (status, output) =
  check bool (label ^ ": " ^ output) true (status <> Unix.WEXITED 0);
  output

let test_seed_passes exe () = with_workspace (fun root ->
  write_runtime_config root (seed ());
  let ambient = Filename.concat root "ambient-workspace" in
  write_runtime_config ambient (seed ());
  (* An ambient selection would still validate the CLI's runtime.toml, but
     would read this invalid Lane directory for its Memory preflight. *)
  let ambient_lanes = Filename.concat ambient ".masc/config/lane-addons" in
  let ambient_bytes = "not a Lane declaration directory\n" in
  write ambient_lanes ambient_bytes;
  List.iter (fun (label, ambient_base_path) ->
    with_env
      [ Env_config_core.base_path_env_key, ambient_base_path
      ; Env_config_keeper.KeeperMemoryOs.librarian_env_key, Some "true" ]
      (fun () ->
        let output = passes label (run_helper exe root []) in
        reports output
          ("runtime.toml accepted path="
           ^ Filename.concat (Unix.realpath root) ".masc/config/runtime.toml");
        reports output "\"state\":\"addon_unattached\"";
        check string "the conflicting workspace is unchanged" ambient_bytes
          (read ambient_lanes)))
    [ "the shipped seed passes without an ambient workspace", None
    ; "the CLI workspace wins over a conflicting ambient workspace", Some ambient ])

(* A persistently invalid source, independent of the retired read-bound
   key. The valid shipped seed is otherwise unchanged. *)
let invalid_source_seed () =
  seed ()
  ^ "\n[[skills.sources]]\nid = \"preflight-invalid\"\nanchor = \"base-path\"\npath = \"../escape\"\naccess = \"read-only\"\n"

let test_invalid_source_refused exe () = with_workspace (fun root ->
  write_runtime_config root (invalid_source_seed ());
  let output = refuses "an escaping Skill source is refused" (run_helper exe root []) in
  reports output "skills.sources[";
  reports output ".path contains a parent-directory component";
  reports output "runtime.toml refused path=";
  reports output (Filename.concat root ".masc/config/runtime.toml"))

(* A relative BasePath names the same file as the absolute one. Before it was
   made absolute, the resolver read <dir>/<dir>/.masc/config and found nothing
   there. *)
let test_relative_base_path_reads_the_file exe () = with_workspace (fun root ->
  write_runtime_config root (invalid_source_seed ());
  let output =
    refuses "a relative BasePath reads the real file"
      (invoke ~cwd:(Filename.dirname root) exe root (Filename.basename root) [])
  in
  reports output ".path contains a parent-directory component";
  reports output (Filename.concat root ".masc/config/runtime.toml"))

(* The raw save checks the Keeper settings before the runtime half, and boot
   refuses to start on them, so a key the registry does not know is refused
   here too. *)
let test_unknown_keeper_setting_refused exe () = with_workspace (fun root ->
  write_runtime_config root (seed () ^ "\n[turn]\ntemperatur = 0.4\n");
  let output = refuses "an unknown Keeper setting is refused" (run_helper exe root []) in
  reports output "turn.temperatur:")

(* Boot keeps running a file whose runtime the model catalog does not carry,
   with that runtime off and the Keeper assigned to it unable to run. The
   catalog is a replacement named by AGENT_CORE_MODEL_CATALOG, which boot
   installs before it loads runtime.toml; the helper has to do the same or it
   judges against another catalog. *)
let degraded_catalog =
  {|[[models]]
model_id = "good"
provider_name = "fixture"
base = "openai_chat"
max_context_tokens = 8192
max_output_tokens = 1024
supports_tools = true
supports_native_streaming = false
|}

let degraded_runtime_toml =
  {|[runtime]
default = "fixture.good"
[runtime.assignments]
affected = "fixture.missing"
healthy = "fixture.good"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9"
[models.good]
api-name = "good"
max-context = 8192
temperature = 0.25
streaming = false
[models.missing]
api-name = "missing"
max-context = 8192
streaming = false
[fixture.good]
[fixture.missing]
|}

let test_degraded_boot_refused exe () = with_workspace (fun root ->
  write_runtime_config root degraded_runtime_toml;
  let catalog = Filename.concat root "catalog.toml" in
  write catalog degraded_catalog;
  let output =
    with_env [ "AGENT_CORE_MODEL_CATALOG", Some catalog ] (fun () ->
      refuses "a Keeper left without its runtime is refused" (run_helper exe root []))
  in
  reports output "Keeper affected assigned to fixture.missing")

(* Boot writes this build's runtime.toml where it is missing unless seeding is
   off, so absence alone refuses nothing. *)
let test_absent_is_seeded_by_boot exe () = with_workspace (fun root ->
  Fs_compat.mkdir_p (Filename.concat root ".masc");
  let output = passes "boot seeds a missing runtime.toml" (run_helper exe root []) in
  reports output "boot_writes_seed=yes")

let test_absent_without_seeding_needs_empty_workspace exe () =
  with_workspace (fun root ->
    Fs_compat.mkdir_p (Filename.concat root ".masc");
    with_env [ "MASC_CONFIG_BOOTSTRAP", Some "skip" ] (fun () ->
      let output =
        refuses "an absent runtime.toml boot does not write is refused"
          (run_helper exe root [])
      in
      reports output "MASC_CONFIG_BOOTSTRAP=skip";
      reports output "--allow-empty-workspace";
      let output =
        passes "an intentional new workspace passes"
          (run_helper exe root ["--allow-empty-workspace"])
      in
      reports output "empty_workspace=allowed"))

(* MASC_CONFIG_BOOTSTRAP=empty starts a new config root without runtime.toml,
   but boot still refills one that already exists. The helper reads that from
   boot's own decision. *)
let test_empty_bootstrap_follows_boot exe () = with_workspace (fun root ->
  Fs_compat.mkdir_p (Filename.concat root ".masc");
  with_env [ "MASC_CONFIG_BOOTSTRAP", Some "empty" ] (fun () ->
    let output =
      refuses "empty bootstrap of a new config root is refused" (run_helper exe root [])
    in
    reports output "MASC_CONFIG_BOOTSTRAP=empty";
    Fs_compat.mkdir_p (Filename.concat root ".masc/config/keepers");
    let output =
      passes "empty bootstrap refills an existing config root" (run_helper exe root [])
    in
    reports output "boot_writes_seed=yes"))

(* A caller may name MASC_CONFIG_DIR before it exists, and boot creates it. *)
let test_missing_config_dir_needs_empty_workspace exe () =
  with_workspace (fun root ->
    let config_dir = Filename.concat root "not-created-yet" in
    with_env [ "MASC_CONFIG_DIR", Some config_dir ] (fun () ->
      let (_ : string) =
        refuses "a MASC_CONFIG_DIR that does not exist is refused" (run_helper exe root [])
      in
      let output =
        passes "an intentional new workspace passes"
          (run_helper exe root ["--allow-empty-workspace"])
      in
      reports output "empty_workspace=allowed"))

(* install-local-build checks the workspace masc itself would use when none is
   named, and asks the helper which one that is, so the order lives in
   Workspace_root alone. *)
let test_resolve_workspace_follows_masc exe () = with_workspace (fun root ->
  let workspace = Filename.concat root "recorded workspace" in
  Fs_compat.mkdir_p (Filename.concat workspace ".masc/config");
  let canonical = Unix.realpath workspace in
  let xdg = Filename.concat root "xdg" in
  Fs_compat.mkdir_p (Filename.concat xdg "masc");
  let resolve extra = run_exe ~cwd:root exe root ("resolve-workspace" :: extra) in
  with_env [ "MASC_BASE_PATH", None; "XDG_CONFIG_HOME", Some xdg ] (fun () ->
    let help = passes "resolve-workspace help identifies a capable helper"
        (resolve [ "--help" ]) in
    reports help "resolve-workspace";
    let output = passes "no workspace is an answer" (resolve []) in
    reports output "workspace=none";
    write (Filename.concat xdg "masc/default-base-path") (canonical ^ "\n");
    let output = passes "the recorded default" (resolve []) in
    reports output "workspace=resolved";
    reports output ("root=" ^ canonical);
    reports output "source=persisted_default";
    let output = passes "a named workspace" (resolve [ "--base-path"; workspace ]) in
    reports output "source=explicit_cli";
    with_env [ "MASC_BASE_PATH", Some workspace ] (fun () ->
      let output = passes "MASC_BASE_PATH" (resolve []) in
      reports output "source=explicit_env")))

(* A deployment command that a signal ends makes the helper exit the way a
   shell reports it: 128 plus the host signal number (#52223). [$$] is the
   command itself. [$PPID] is the helper, which forwards the signal to the
   command's process group. The [lease-handoff] preparation fails here, so
   its next executable never runs. *)
let signalled_commands =
  [ "kill -TERM $$", 143
  ; "kill -KILL $$", 137
  ; "kill -TERM $PPID; exec sleep 5", 143 ]

let lease_run root = [ "lease-run"; "--base-path"; root ]

let lease_handoff root =
  [ "lease-handoff"; "--base-path"; root; "--next-executable"; "/bin/sh" ]

let test_signalled_command_exit_code exe subcommand () = with_workspace (fun root ->
  List.iter (fun (script, expected) ->
    let status, output =
      run_exe exe root (subcommand root @ [ "--"; "/bin/sh"; "-c"; script ])
    in
    match status with
    | Unix.WEXITED code -> check int (script ^ ": " ^ output) expected code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      fail ("the helper itself did not exit after " ^ script ^ ": " ^ output))
    signalled_commands)

let rec waitpid_nointr pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

(* The real helper A owns the lease while its preparation waits for EOF on
   stdin. Its environment reports A's PID only after acquisition. Both pipes
   are close-on-exec apart from the child's standard streams, so closing our
   writer releases the preparation even when an assertion fails. *)
let with_lease_holder exe root f =
  let command_input, release = Unix.pipe ~cloexec:true () in
  let ready, command_output = Unix.pipe ~cloexec:true () in
  let errors_path = Filename.concat root "holder-stderr" in
  let errors = Unix.openfile errors_path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC] 0o600 in
  let exe = absolute exe in
  let arguments = Array.of_list
      (exe :: lease_run root @ ["--"; "/bin/sh"; "-c";
        "printf '%s\\n' \"$MASC_DEPLOYMENT_LEASE_OWNER_PID\"; IFS= read -r released; exit 0"]) in
  let pid =
    try Unix.create_process exe arguments command_input command_output errors with
    | exn -> (* cancel-guard-ok: Unix.create_process performs no Eio operation. *)
      List.iter Unix.close [command_input; release; ready; command_output; errors];
      raise exn
  in
  List.iter Unix.close [command_input; command_output; errors];
  let ready = Unix.in_channel_of_descr ready in
  let release = Unix.out_channel_of_descr release in
  let ended = ref None in
  let result = Fun.protect
      ~finally:(fun () ->
        close_out_noerr release;
        close_in_noerr ready;
        ended := Some (waitpid_nointr pid))
      (fun () ->
        let reported = input_line ready |> int_of_string in
        check int "the acquired lease belongs to helper A" pid reported;
        f pid)
  in
  (match !ended with
   | Some (Unix.WEXITED 0) -> ()
   | Some (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) | None ->
     fail ("the actual lease holder did not finish cleanly: " ^ read errors_path));
  result

(* Find the actual helper-created lease under this test's otherwise empty
   override, without copying the product's inode-derived filename algorithm. *)
let rec lease_files path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path |> Array.to_list |> List.concat_map (fun name ->
      lease_files (Filename.concat path name))
  | Unix.S_REG -> [path]
  | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
    fail "the fixture lease root contains an unexpected file kind"

let verify_owner exe root owner =
  run_exe exe root ["verify-lease-owner"; "--base-path"; root;
    "--owner-pid"; string_of_int owner]

let test_lease_owner_uses_kernel exe () = with_workspace (fun root ->
  let parent_pid = Unix.getpid () in
  let path = with_lease_holder exe root (fun holder_pid ->
    let path = match lease_files (lease_root root) with
      | [path] -> path
      | [] | _ :: _ -> fail "the actual helper did not create exactly one lease file" in
    let (_ : string) = passes "the actual acquired owner passes"
        (verify_owner exe root holder_pid) in
    List.iter (fun advisory ->
      write path advisory;
      let (_ : string) = refuses "the live parent C is not lease holder A"
          (verify_owner exe root parent_pid) in
      check string "a refused observation preserves advisory bytes" advisory (read path);
      let (_ : string) = passes "the kernel owner passes independently of advisory bytes"
          (verify_owner exe root holder_pid) in
      check string "an accepted observation preserves advisory bytes" advisory (read path))
      [Printf.sprintf "%d\n" parent_pid; ""; "not a process identity\n"];
    path) in
  (* A has actually exited and released its lock before these observations. *)
  List.iter (fun advisory ->
    write path advisory;
    let (_ : string) = refuses "an unlocked lease is not owned by the live parent"
        (verify_owner exe root parent_pid) in
    check string "unlocked verification never rewrites the PID file" advisory (read path))
    [Printf.sprintf "%d\n" parent_pid; ""; "not a process identity\n"];
  Unix.unlink path;
  let (_ : string) = refuses "a removed lease remains absent"
      (verify_owner exe root parent_pid) in
  check bool "the removed lease file was not recreated" false (Sys.file_exists path))

let test_lease_owner_absence_is_read_only exe () = with_workspace (fun root ->
  Unix.rmdir (lease_root root);
  let (_ : string) = refuses "a never-held lease is not an owner proof"
      (verify_owner exe root (Unix.getpid ())) in
  check bool "the lease override was not created" false (Sys.file_exists (lease_root root));
  check bool "the runtime directory was not created" false
    (Sys.file_exists (Filename.concat root ".masc")))

let test_lease_owner_rejects_invalid_and_self exe () = with_workspace (fun root ->
  Unix.rmdir (lease_root root);
  List.iter (fun owner ->
    let (_ : string) = refuses "a nonpositive expected owner is refused"
        (verify_owner exe root owner) in ()) [0; -1];
  let (_ : string) = refuses "the verifying helper cannot name itself as another owner"
      (run_exe "/bin/sh" root ["-c";
        "exec \"$1\" verify-lease-owner --base-path \"$2\" --owner-pid \"$$\"";
        "verify-self"; absolute exe; root]) in
  check bool "invalid and self observations create no lease paths" false
    (Sys.file_exists (lease_root root));
  let malformed_root = "not a lease directory\n" in
  write (lease_root root) malformed_root;
  let (_ : string) = refuses "an invalid lease boundary is not an owner proof"
      (verify_owner exe root (Unix.getpid ())) in
  check string "a rejected lease boundary is unchanged" malformed_root
    (read (lease_root root)))

let () =
  let exe = Sys.getenv "MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE" in
  run "deployment runtime config"
    ["validate-runtime-config",
     [test_case "the shipped seed passes" `Quick (test_seed_passes exe);
      test_case "an escaping Skill source is refused" `Quick
        (test_invalid_source_refused exe);
      test_case "a relative BasePath reads the real file" `Quick
        (test_relative_base_path_reads_the_file exe);
      test_case "an unknown Keeper setting is refused" `Quick
        (test_unknown_keeper_setting_refused exe);
      test_case "a degraded boot is refused" `Quick (test_degraded_boot_refused exe);
      test_case "boot seeds a missing runtime.toml" `Quick
        (test_absent_is_seeded_by_boot exe);
      test_case "an unseeded absent runtime.toml needs an empty workspace" `Quick
        (test_absent_without_seeding_needs_empty_workspace exe);
      test_case "empty bootstrap follows boot's config-root decision" `Quick
        (test_empty_bootstrap_follows_boot exe);
      test_case "resolve-workspace follows masc's order" `Quick
        (test_resolve_workspace_follows_masc exe);
      test_case "a missing MASC_CONFIG_DIR needs an empty workspace" `Quick
        (test_missing_config_dir_needs_empty_workspace exe)];
     "kernel lease owner verification",
     [test_case "the real holder wins over advisory PID bytes and free files stay unchanged" `Quick
        (test_lease_owner_uses_kernel exe);
      test_case "an absent lease creates no paths" `Quick
        (test_lease_owner_absence_is_read_only exe);
      test_case "nonpositive and self owner expectations are refused" `Quick
        (test_lease_owner_rejects_invalid_and_self exe)];
     "signalled deployment command",
     [test_case "lease-run exits 128 plus the host signal number" `Quick
        (test_signalled_command_exit_code exe lease_run);
      test_case "lease-handoff preparation exits 128 plus the host signal number" `Quick
        (test_signalled_command_exit_code exe lease_handoff)]]
