open Alcotest

(* [validate-runtime-config] is what the deployment gate runs on the
   runtime.toml a workspace's server reads (#39311). Each case runs the built
   helper on a throwaway BasePath, as the gate does. MASC_CONFIG_DIR is unset
   so the file under that BasePath is the one read. *)

let read path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let invoke exe root extra =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let output = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let errors = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let status = Fun.protect ~finally:(fun () -> Unix.close output; Unix.close errors) (fun () ->
    let argv = exe :: "validate-runtime-config" :: "--base-path" :: root :: extra in
    let pid = Unix.create_process exe (Array.of_list argv) Unix.stdin output errors in
    snd (Unix.waitpid [] pid)) in
  status, read stdout_path ^ read stderr_path

let with_workspace f =
  let root = Filename.temp_dir "preflight-runtime-config-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Masc_test_deps.with_process_env "MASC_CONFIG_DIR" None (fun () -> f root))

let write_runtime_config root text =
  let config = Filename.concat root ".masc/config" in
  Fs_compat.mkdir_p config;
  write (Filename.concat config "runtime.toml") text

let seed () = read (Sys.getenv "MASC_TEST_RUNTIME_SEED")

let reports output expected =
  check bool ("reports " ^ expected ^ ": " ^ output) true
    (String_util.contains_substring output expected)

let test_seed_passes exe () = with_workspace (fun root ->
  write_runtime_config root (seed ());
  let status, output = invoke exe root [] in
  check bool ("the shipped seed passes: " ^ output) true (status = Unix.WEXITED 0);
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
  let status, output = invoke exe root [] in
  check bool ("the pre-#39040 bound is refused: " ^ output) true (status <> Unix.WEXITED 0);
  reports output "[skills] resource-read-max-bytes = 65536";
  reports output "runtime.toml refused path=";
  reports output ".masc/config/runtime.toml")

(* The raw save checks the Keeper settings before the runtime half, so a key
   the registry does not know is refused here as it is there. *)
let test_unknown_keeper_setting_refused exe () = with_workspace (fun root ->
  write_runtime_config root (seed () ^ "\n[turn]\ntemperatur = 0.4\n");
  let status, output = invoke exe root [] in
  check bool ("an unknown Keeper setting is refused: " ^ output) true
    (status <> Unix.WEXITED 0);
  reports output "turn.temperatur")

(* A workspace with state and no runtime.toml boots without a model. Only an
   intentional new workspace passes that. *)
let test_absent_needs_empty_workspace exe () = with_workspace (fun root ->
  Fs_compat.mkdir_p (Filename.concat root ".masc");
  let status, output = invoke exe root [] in
  check bool ("an absent runtime.toml is refused: " ^ output) true
    (status <> Unix.WEXITED 0);
  reports output "--allow-empty-workspace";
  let status, output = invoke exe root ["--allow-empty-workspace"] in
  check bool ("an intentional new workspace passes: " ^ output) true
    (status = Unix.WEXITED 0);
  reports output "empty_workspace=allowed")

let () =
  let exe = Sys.getenv "MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE" in
  run "deployment runtime config"
    ["validate-runtime-config",
     [test_case "the shipped seed passes" `Quick (test_seed_passes exe);
      test_case "an over-bound Skill resource bound is refused" `Quick
        (test_over_bound_refused exe);
      test_case "an unknown Keeper setting is refused" `Quick
        (test_unknown_keeper_setting_refused exe);
      test_case "an absent runtime.toml needs an empty workspace" `Quick
        (test_absent_needs_empty_workspace exe)]]
