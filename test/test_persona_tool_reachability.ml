(** test_persona_tool_reachability — tool_access group reachability.

    Locks the reusable tool groups that keepers can reference from explicit
    [tool_access] lists. *)

open Masc

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      Bytes.unsafe_to_string buf)

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_repo_root parent

let locate_tool_policy_toml () =
  match find_repo_root (Sys.getcwd ()) with
  | Some root -> Filename.concat root "config/tool_policy.toml"
  | None ->
      Alcotest.fail "could not locate dune-project ancestor of cwd"

(** Find the [tools = [...]] line inside a [groups.<name>] section. *)
let extract_group_tools_line ~group toml_content =
  let header = Printf.sprintf "[groups.%s]" group in
  let lines = String.split_on_char '\n' toml_content in
  let rec scan_section = function
    | [] -> None
    | line :: rest ->
        let trimmed = String.trim line in
        if String.length trimmed > 0 && trimmed.[0] = '[' then
          (* hit next section without finding tools *)
          None
        else if
          String_util.contains_substring trimmed "tools"
          && String_util.contains_substring trimmed "="
        then Some trimmed
        else scan_section rest
  in
  let rec find_section = function
    | [] -> None
    | line :: rest when String_util.contains_substring line header ->
        scan_section rest
    | _ :: rest -> find_section rest
  in
  find_section lines

let assert_tool_in_line ~group ~tool line =
  let needle = "\"" ^ tool ^ "\"" in
  Alcotest.(check bool)
    (Printf.sprintf "group %s includes tool %s" group tool)
    true
    (String_util.contains_substring line needle)

let test_tool_access_groups_present () =
  let path = locate_tool_policy_toml () in
  let content = read_file path in
  List.iter
    (fun group ->
      Alcotest.(check bool)
        ("tool_policy.toml has [groups." ^ group ^ "] header")
        true
        (String_util.contains_substring content ("[groups." ^ group ^ "]")))
    [ "filesystem"; "workspace_write"; "search_files"; "execute" ]

let test_tool_access_groups_include_expected_tools () =
  let path = locate_tool_policy_toml () in
  let content = read_file path in
  let check_group group tools =
    match extract_group_tools_line ~group content with
    | None -> Alcotest.failf "missing tools line for group %s" group
    | Some line -> List.iter (fun tool -> assert_tool_in_line ~group ~tool line) tools
  in
  check_group "filesystem" [ "tool_read_file" ];
  check_group "workspace_write" [ "tool_edit_file"; "tool_write_file" ];
  check_group "search_files" [ "tool_search_files" ];
  check_group "execute" [ "tool_execute" ]

let () =
  Alcotest.run "persona_tool_reachability"
    [
      ( "tool_access_groups",
        [
          Alcotest.test_case "tool access groups present" `Quick
            test_tool_access_groups_present;
          Alcotest.test_case "tool access groups include expected tools" `Quick
            test_tool_access_groups_include_expected_tools;
        ] );
    ]
