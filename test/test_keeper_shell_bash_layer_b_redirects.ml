(** P0-X Layer B integration tests for the typed-redirect arms in
    [keeper_shell_bash_shape_messages.ml:331-368].

    Predicate-level coverage already lives in
    [test_keeper_shell_bash_cross_repo_discovery.ml]; Layer A scaffold
    pattern (Eio/config bootstrap, [handle_keeper_bash] direct call,
    JSON field assertions) comes from
    [test_keeper_shell_bash_cross_host_probe.ml].

    This module exercises the full path:
      keeper_bash invocation
        -> bash_shape_block detection ([Repo_wide_scan])
        -> [bash_shape_block_recovery_plan] wildcard arms #1/#2 fire
        -> [recovery_plan_extra] stamps [recovery_plan] block in JSON.

    Notes on JSON shape (verified against
    [keeper_shell_bash.ml:543-589] + [keeper_shell_bash.ml:458-470] +
    [keeper_shell_bash_shape_messages.ml:152-160]):
      - [error] = "keeper_bash_command_shape_blocked"
      - [shape_block] = "repo_wide_scan" (the shape arm hit)
      - [recovery_rule_id] = "keeper_bash_repo_wide_scan_blocked"
      - [required_next_tool] = plan.next_tool ("masc_worktree_list" / "Grep")
      - [recovery_plan.reason] discriminates the arm:
        "worktree_discovery_tool_ssot" / "cross_repo_grep_scoped_redirect"
      - [recovery_plan.next_args] carries the structured arguments. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Json = Yojson.Safe.Util

let playground_path_of = Masc_mcp.Keeper_alerting_path.playground_path_of_keeper

let temp_dir () =
  let dir = Filename.temp_file "keeper_bash_layer_b_redirects_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_config () =
  let tmp = temp_dir () in
  ensure_dir (Filename.concat tmp Common.masc_dirname);
  (tmp, Coord.default_config tmp)

let make_readonly_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "layer B redirect scaffold");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_readonly_meta failed: " ^ err)

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let parse_string_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let parse_recovery_plan_field raw field =
  Yojson.Safe.from_string raw
  |> Json.member "recovery_plan"
  |> Json.member field

(* Defensive accessors: when no shape arm fires, [recovery_plan] is
   absent from the JSON entirely, so [member "reason"] would otherwise
   walk into a [`Null] value and the type-error raises. Treat absent as
   [None] (which is what the negative tests want to express). *)
let recovery_plan_reason raw =
  try parse_recovery_plan_field raw "reason" |> Json.to_string_option
  with Json.Type_error _ -> None

let recovery_plan_next_tool raw =
  try parse_recovery_plan_field raw "next_tool" |> Json.to_string_option
  with Json.Type_error _ -> None

let recovery_plan_next_args raw =
  try parse_recovery_plan_field raw "next_args"
  with Json.Type_error _ -> `Null

let run_keeper_bash ~name ~cmd =
  let base_path, config = make_config () in
  let cleanup () = cleanup_dir base_path in
  Fun.protect ~finally:cleanup @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta name in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  Keeper_exec_shell.handle_keeper_bash
    ~turn_sandbox_factory:None
    ~turn_sandbox_factory_git:None
    ~exec_cache:None
    ~config
    ~meta
    ~args:
      (`Assoc
         [ ("cmd", `String cmd)
         ; ("cwd", `String playground)
         ])
    ()

(* ----------------------------------------------------------------- *)
(* Test 1: pattern #1 worktree discovery -> masc_worktree_list redirect. *)
(* ----------------------------------------------------------------- *)

let test_worktree_discovery_emits_masc_worktree_list_redirect () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"worktree-find"
      ~cmd:"find repos -maxdepth 4 -type d -name .worktrees"
  in
  Alcotest.(check (option string))
    "error = keeper_bash_command_shape_blocked"
    (Some "keeper_bash_command_shape_blocked")
    (parse_string_field raw "error");
  Alcotest.(check (option string))
    "shape_block = repo_wide_scan"
    (Some "repo_wide_scan")
    (parse_string_field raw "shape_block");
  Alcotest.(check (option string))
    "required_next_tool = masc_worktree_list"
    (Some "masc_worktree_list")
    (parse_string_field raw "required_next_tool");
  Alcotest.(check (option string))
    "recovery_plan.next_tool = masc_worktree_list"
    (Some "masc_worktree_list")
    (recovery_plan_next_tool raw);
  Alcotest.(check (option string))
    "recovery_plan.reason = worktree_discovery_tool_ssot"
    (Some "worktree_discovery_tool_ssot")
    (recovery_plan_reason raw);
  (* recovery_rule_id is the shape-block-level tag, NOT the arm-level
     reason; pin its present shape so a future arm split is visible. *)
  Alcotest.(check (option string))
    "recovery_rule_id = keeper_bash_repo_wide_scan_blocked"
    (Some "keeper_bash_repo_wide_scan_blocked")
    (parse_string_field raw "recovery_rule_id");
  (* next_args carries [include_remote=false] per shape_messages.ml:339. *)
  let next_args = recovery_plan_next_args raw in
  let include_remote =
    next_args |> Json.member "include_remote" |> Json.to_bool_option
  in
  Alcotest.(check (option bool))
    "recovery_plan.next_args.include_remote = false"
    (Some false)
    include_remote

(* ----------------------------------------------------------------- *)
(* Test 2: pattern #2 cross-repo grep -> Grep redirect with structured args. *)
(* ----------------------------------------------------------------- *)

let test_cross_repo_grep_emits_grep_redirect_with_structured_args () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"cross-repo-rg"
      ~cmd:{|rg -l "current_task" repos/|}
  in
  Alcotest.(check (option string))
    "error = keeper_bash_command_shape_blocked"
    (Some "keeper_bash_command_shape_blocked")
    (parse_string_field raw "error");
  Alcotest.(check (option string))
    "shape_block = repo_wide_scan"
    (Some "repo_wide_scan")
    (parse_string_field raw "shape_block");
  Alcotest.(check (option string))
    "required_next_tool = Grep"
    (Some "Grep")
    (parse_string_field raw "required_next_tool");
  Alcotest.(check (option string))
    "recovery_plan.next_tool = Grep"
    (Some "Grep")
    (recovery_plan_next_tool raw);
  Alcotest.(check (option string))
    "recovery_plan.reason = cross_repo_grep_scoped_redirect"
    (Some "cross_repo_grep_scoped_redirect")
    (recovery_plan_reason raw);
  let next_args = recovery_plan_next_args raw in
  let pattern =
    next_args |> Json.member "pattern" |> Json.to_string_option
  in
  let path =
    next_args |> Json.member "path" |> Json.to_string_option
  in
  let glob =
    next_args |> Json.member "glob" |> Json.to_string_option
  in
  Alcotest.(check (option string))
    "recovery_plan.next_args.pattern preserves rg -l <pattern>"
    (Some "current_task")
    pattern;
  Alcotest.(check (option string))
    "recovery_plan.next_args.path = repos/REPO/SCOPED_PATH placeholder"
    (Some "repos/REPO/SCOPED_PATH")
    path;
  Alcotest.(check (option string))
    "recovery_plan.next_args.glob = *.ml default"
    (Some "*.ml")
    glob

(* ----------------------------------------------------------------- *)
(* Test 3: negative for pattern #1 -- [find . ...] without [.worktrees]
   keyword does NOT trigger the worktree_discovery redirect arm. (May
   still hit some other shape block; the assertion only pins the arm
   was NOT taken.) *)
(* ----------------------------------------------------------------- *)

let test_worktree_discovery_negative_no_worktrees_keyword () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"worktree-negative"
      ~cmd:"find . -maxdepth 4 -type d -name foo"
  in
  let next_tool = parse_string_field raw "required_next_tool" in
  Alcotest.(check bool)
    "required_next_tool is NOT masc_worktree_list"
    true
    (next_tool <> Some "masc_worktree_list");
  let reason = recovery_plan_reason raw in
  Alcotest.(check bool)
    "recovery_plan.reason is NOT worktree_discovery_tool_ssot"
    true
    (reason <> Some "worktree_discovery_tool_ssot")

(* ----------------------------------------------------------------- *)
(* Test 4: negative for pattern #2 -- [grep "TODO" src/foo.ts] points
   at a scoped path (no leading [ repos/]), so the cross_repo_grep
   redirect arm must NOT fire. (May still hit a different shape block
   like [Pipe_or_redirect] depending on tokens.) *)
(* ----------------------------------------------------------------- *)

let test_cross_repo_grep_negative_scoped_src_path () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"cross-repo-grep-negative"
      ~cmd:{|grep "TODO" src/foo.ts|}
  in
  let reason = recovery_plan_reason raw in
  Alcotest.(check bool)
    "recovery_plan.reason is NOT cross_repo_grep_scoped_redirect"
    true
    (reason <> Some "cross_repo_grep_scoped_redirect");
  (* Defensively also assert next_tool!=Grep with the placeholder path,
     so a future regression that loosens the predicate (matching
     anything containing [grep ]) gets caught. *)
  let next_args = recovery_plan_next_args raw in
  let path =
    try next_args |> Json.member "path" |> Json.to_string_option
    with Json.Type_error _ -> None
  in
  Alcotest.(check bool)
    "recovery_plan.next_args.path is NOT the cross_repo placeholder"
    true
    (path <> Some "repos/REPO/SCOPED_PATH")

let () =
  Alcotest.run
    "keeper_shell_bash_layer_b_redirects"
    [
      ( "Layer B typed-redirect arms (worktree_discovery + cross_repo_grep)",
        [
          Alcotest.test_case
            "pattern #1: find repos -name .worktrees -> masc_worktree_list"
            `Quick
            test_worktree_discovery_emits_masc_worktree_list_redirect;
          Alcotest.test_case
            "pattern #2: rg -l current_task repos/ -> Grep with scoped args"
            `Quick
            test_cross_repo_grep_emits_grep_redirect_with_structured_args;
          Alcotest.test_case
            "pattern #1 negative: find . -name foo (no .worktrees)"
            `Quick
            test_worktree_discovery_negative_no_worktrees_keyword;
          Alcotest.test_case
            "pattern #2 negative: grep TODO src/foo.ts (scoped path)"
            `Quick
            test_cross_repo_grep_negative_scoped_src_path;
        ] );
    ]
