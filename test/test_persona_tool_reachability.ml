(** test_persona_tool_reachability — Step 15 partial.

    Locks the Step 9 (research preset = delivery) capability decision
    so a future PR cannot silently narrow research-tier keepers' tool
    surface without failing this test.

    The Step 9 unblock at [config/tool_policy.toml]
    [\[presets.research\]] is what makes delivery-class filesystem, shell,
    and execute tooling reach the research-tier toolset.  Before Step
    9, analyst / scholar / verifier keepers could only share opinions on
    the board.  After Step 9, the capability is opened and the
    risk-tiered approval gate still queues high-risk ops for operator
    confirmation.  This test is the regression sentinel for that
    decision. *)

open Masc_mcp

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

(** Find the line [groups = [...]] inside the [[presets.<name>]]
    section.  Returns the line with its [...] payload as one string
    so callers can search for quoted group names without dragging
    in a TOML parser. *)
let extract_preset_groups_line ~preset toml_content =
  let header = Printf.sprintf "[presets.%s]" preset in
  let lines = String.split_on_char '\n' toml_content in
  let rec scan_section = function
    | [] -> None
    | line :: rest ->
        let trimmed = String.trim line in
        if String.length trimmed > 0 && trimmed.[0] = '[' then
          (* hit next section without finding groups *)
          None
        else if
          String_util.contains_substring trimmed "groups"
          && String_util.contains_substring trimmed "="
          && not
               (String_util.contains_substring trimmed "masc_groups")
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

let assert_group_in_line ~preset ~group line =
  let needle = "\"" ^ group ^ "\"" in
  Alcotest.(check bool)
    (Printf.sprintf "preset %s includes group %s" preset group)
    true
    (String_util.contains_substring line needle)

(** Step 9 invariant: research preset has the delivery-class capability
    groups so analyst/scholar/verifier keepers can clone, view PRs, and
    create PRs (the risk-tiered approval gate still applies). *)
let test_research_preset_includes_delivery_groups () =
  let path = locate_tool_policy_toml () in
  let content = read_file path in
  match extract_preset_groups_line ~preset:"research" content with
  | None ->
      Alcotest.fail
        "could not find [presets.research].groups in tool_policy.toml"
  | Some line ->
      List.iter
        (fun group ->
          assert_group_in_line ~preset:"research" ~group line)
        [
          "execute";
          "shell";
          "filesystem_write";
        ]

(** Sanity baseline: delivery preset keeps the production work groups.  If
    this test fails, the TOML schema or the [delivery] preset shape
    changed and the [research] expectation likely needs revisiting
    in the same PR. *)
let test_delivery_preset_baseline () =
  let path = locate_tool_policy_toml () in
  let content = read_file path in
  match extract_preset_groups_line ~preset:"delivery" content with
  | None ->
      Alcotest.fail
        "could not find [presets.delivery].groups in tool_policy.toml"
  | Some line ->
      List.iter
        (fun group ->
          assert_group_in_line ~preset:"delivery" ~group line)
        [
          "execute";
          "shell";
          "filesystem_write";
        ]

(** Anchor: research preset header is well-formed and not commented out.
    Catches the trivial regression where the section header itself was
    accidentally renamed or stripped. *)
let test_research_preset_section_present () =
  let path = locate_tool_policy_toml () in
  let content = read_file path in
  Alcotest.(check bool)
    "tool_policy.toml has [presets.research] header" true
    (String_util.contains_substring content "[presets.research]")

let () =
  Alcotest.run "persona_tool_reachability"
    [
      ( "research_preset",
        [
          Alcotest.test_case "section header present" `Quick
            test_research_preset_section_present;
          Alcotest.test_case "includes delivery groups (Step 9)" `Quick
            test_research_preset_includes_delivery_groups;
        ] );
      ( "delivery_preset",
        [
          Alcotest.test_case "baseline delivery groups" `Quick
            test_delivery_preset_baseline;
        ] );
    ]
