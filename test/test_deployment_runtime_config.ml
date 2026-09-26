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

(* [cwd] is where the helper starts, for a relative BasePath. *)
let invoke ?cwd exe root argument extra =
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
      let argv = exe :: "validate-runtime-config" :: "--base-path" :: argument :: extra in
      let pid = Unix.create_process exe (Array.of_list argv) Unix.stdin output errors in
      snd (Unix.waitpid [] pid)) in
  status, read stdout_path ^ read stderr_path

let run_helper exe root extra = invoke exe root root extra

let with_env pairs f =
  List.fold_right
    (fun (key, value) f () -> Masc_test_deps.with_process_env key value f)
    pairs f ()

let with_workspace f =
  let root = Filename.temp_dir "preflight-runtime-config-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    with_env
      [ "MASC_CONFIG_DIR", None
      ; "MASC_CONFIG_BOOTSTRAP", None
      ; "AGENT_CORE_MODEL_CATALOG", None ]
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
  let output = passes "the shipped seed passes" (run_helper exe root []) in
  reports output "runtime.toml accepted path=";
  reports output ".masc/config/runtime.toml")

(* The #39311 shape: the seed with the Skill resource bound it had before
   #39040 narrowed the key. *)
let over_bound_seed () =
  let is_bound line = String.starts_with ~prefix:"resource-read-max-bytes =" line in
  let lines = String.split_on_char '\n' (seed ()) in
  check int "the seed declares the Skill resource bound once" 1
    (List.length (List.filter is_bound lines));
  lines
  |> List.map (fun line -> if is_bound line then "resource-read-max-bytes = 65536" else line)
  |> String.concat "\n"

let test_over_bound_refused exe () = with_workspace (fun root ->
  write_runtime_config root (over_bound_seed ());
  let output = refuses "the pre-#39040 bound is refused" (run_helper exe root []) in
  reports output "[skills] resource-read-max-bytes = 65536";
  reports output "runtime.toml refused path=";
  reports output ".masc/config/runtime.toml")

(* A relative BasePath names the same file as the absolute one. Before it was
   made absolute, the resolver read <dir>/<dir>/.masc/config and found nothing
   there. *)
let test_relative_base_path_reads_the_file exe () = with_workspace (fun root ->
  write_runtime_config root (over_bound_seed ());
  let output =
    refuses "a relative BasePath reads the real file"
      (invoke ~cwd:(Filename.dirname root) exe root (Filename.basename root) [])
  in
  reports output "[skills] resource-read-max-bytes = 65536")

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
id_prefix = "good"
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

(* scripts/deploy.sh names MASC_CONFIG_DIR itself, and boot creates it. *)
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

let () =
  let exe = Sys.getenv "MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE" in
  run "deployment runtime config"
    ["validate-runtime-config",
     [test_case "the shipped seed passes" `Quick (test_seed_passes exe);
      test_case "an over-bound Skill resource bound is refused" `Quick
        (test_over_bound_refused exe);
      test_case "a relative BasePath reads the real file" `Quick
        (test_relative_base_path_reads_the_file exe);
      test_case "an unknown Keeper setting is refused" `Quick
        (test_unknown_keeper_setting_refused exe);
      test_case "a degraded boot is refused" `Quick (test_degraded_boot_refused exe);
      test_case "boot seeds a missing runtime.toml" `Quick
        (test_absent_is_seeded_by_boot exe);
      test_case "an unseeded absent runtime.toml needs an empty workspace" `Quick
        (test_absent_without_seeding_needs_empty_workspace exe);
      test_case "a missing MASC_CONFIG_DIR needs an empty workspace" `Quick
        (test_missing_config_dir_needs_empty_workspace exe)]]
