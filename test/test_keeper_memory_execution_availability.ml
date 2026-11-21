open Alcotest
open Masc
module A = Keeper_memory_execution_availability
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string

let test_real_manifest_parse_error_stays_in_authenticated_diagnostics () =
  let root=Filename.temp_dir "memory-private-config-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let directory=Filename.concat root "lane-addons" in
    Fs_compat.mkdir_p directory;
    let manifest=Filename.concat root "private-package.toml" in
    let sentinel="PRIVATE_MARKER" in
    let write path bytes=Out_channel.with_open_bin path (fun channel -> output_string channel bytes) in
    write manifest (Printf.sprintf
      "id=\"unrelated\"\nrevision=\"1\"\ntitle=\"Unrelated package\"\ncontributions=[\"observe\"]\nimage=\"fixture\"\ncommand=[\"fixture\"]\n[interface]\nbinding_schema='''%s'''\n" sentinel);
    write (Filename.concat directory "unrelated.toml") (Printf.sprintf
      "id=\"unrelated\"\nrun_id=\"unrelated\"\nmanifest_path=%S\n[binding]\nsources=[]\n" manifest);
    let declarations=Lane_addon_config.load ~packages:(Config_dir_resolver.packages_dir ~base_path:root) ~directory in
    check bool "the real parser retains offending input in its operator diagnostic" true
      (List.exists (fun (issue : Lane_addon_config.issue) ->
        Astring.String.is_infix ~affix:sentinel issue.message) declarations.issues);
    let public=A.observe ~setting:Env_config_keeper.KeeperMemoryOs.Enabled ~declarations
      ~route:(fun _ -> fail "invalid configuration cannot admit routes") ~mode:A.Preflight |> A.to_json in
    check string "public health still names configuration failure" "degraded" (text "status" public);
    let bytes=Yojson.Safe.to_string public in
    check bool "private parser input is not public health" false (Astring.String.is_infix ~affix:sentinel bytes);
    check bool "private source paths are not public health" false (Astring.String.is_infix ~affix:root bytes);
    let operation=member "operations" public |> Yojson.Safe.Util.to_list |> List.hd in
    let issue=member "detail" operation |> Yojson.Safe.Util.to_list |> List.hd in
    check string "public failure retains the declaration identity" "unrelated" (text "installation_id" issue);
    check string "public failure is a fixed category" "declaration_unavailable" (text "reason" issue);
    check string "public failure names the declaration file inside the Lane directory" "unrelated.toml"
      (text "declaration_file" issue);
    (* A Lane directory that cannot be listed has no file to name. *)
    let unlistable=Filename.concat root "not-a-directory" in
    write unlistable "a file";
    let public=A.observe ~setting:Env_config_keeper.KeeperMemoryOs.Enabled
      ~declarations:(Lane_addon_config.load ~packages:(Config_dir_resolver.packages_dir ~base_path:root) ~directory:unlistable)
      ~route:(fun _ -> fail "invalid configuration cannot admit routes") ~mode:A.Preflight |> A.to_json in
    check bool "private source paths are not public health" false
      (Astring.String.is_infix ~affix:root (Yojson.Safe.to_string public));
    let issue=member "operations" public |> Yojson.Safe.Util.to_list |> List.hd
      |> member "detail" |> Yojson.Safe.Util.to_list |> List.hd in
    check string "a directory failure says so" "lane_directory" (text "source" issue);
    check bool "and names no file" true (member "declaration_file" issue = `Null))

let () = run "Keeper Memory execution dependencies"
  ["configuration",[
    test_case "real manifest parse errors do not expose input or paths" `Quick test_real_manifest_parse_error_stays_in_authenticated_diagnostics]]
