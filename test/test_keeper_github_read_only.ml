(** Tests for [Keeper_tool_registry.is_read_only_with_input].

    Validates input-aware read-only classification for keeper_shell op=gh:
    1. Read-only gh subcommands (pr list, issue view, etc.) via cmd
    2. Mutating gh subcommands are not classified as read-only
    3. gh api GET (default) is read-only
    4. gh api with -X POST/PUT/DELETE is mutating
    5. gh api with -f/-F (implicit POST) is mutating
    6. gh api graphql is mutating (always POST)
    7. Edge cases: empty input, non-gh tools, whitespace *)

open Masc_mcp

let is_ro ~tool_name ~input =
  Keeper_tool_registry.is_read_only_with_input ~tool_name ~input

let has_side_effect ~tool_name ~input =
  Keeper_exec_tools.has_mutating_side_effect_with_input ~tool_name ~input

let is_boundary_exempt ~tool_name ~input =
  Keeper_tool_registry.is_main_worktree_boundary_exempt_with_input
    ~tool_name ~input

let mk_cmd cmd =
  `Assoc [ ("op", `String "gh"); ("cmd", `String cmd) ]

(* Legacy helpers for backward compat with older tests (not exercised;
   keeper_shell op=gh only accepts cmd, not args). *)
let mk_args args =
  `Assoc [ ("op", `String "gh");
           ("cmd", `String (String.concat " " args)) ]

let mk_cmd_and_args cmd _args =
  `Assoc [ ("op", `String "gh"); ("cmd", `String cmd) ]

let mk_action action =
  `Assoc [ ("action", `String action) ]

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let temp_dir () =
  let dir = Filename.temp_file "keeper_gh_context_" "" in
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
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let run_argv argv =
  let command = String.concat " " (List.map Filename.quote argv) in
  match Unix.system command with
  | Unix.WEXITED 0 -> ()
  | _ ->
    Alcotest.fail
      (Printf.sprintf "command failed: %s\n%s"
         (String.concat " " argv)
         command)

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_fake_gh script f =
  let dir = temp_dir () in
  let gh_path = Filename.concat dir "gh" in
  let oc = open_out_bin gh_path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      cleanup_dir dir)
    (fun () ->
      output_string oc script;
      close_out oc;
      Unix.chmod gh_path 0o755;
      let path =
        match Sys.getenv_opt "PATH" with
        | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
        | _ -> dir
      in
      with_env "PATH" path f)

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  let oc = open_out_bin docker_path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      cleanup_dir dir)
    (fun () ->
      output_string oc script;
      close_out oc;
      Unix.chmod docker_path 0o755;
      let path =
        match Sys.getenv_opt "PATH" with
        | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
        | _ -> dir
      in
      with_env "PATH" path f)

let make_meta ?current_task_id ?(sandbox_profile = Keeper_types.Local) () =
  let base_fields =
    [
      ("name", `String "sojin");
      ("agent_name", `String "agent-sojin");
      ("trace_id", `String "trace-sojin");
      ("goal", `String "gh context test");
      ("allowed_paths", `List [ `String "*" ]);
      ( "sandbox_profile",
        `String (Keeper_types.sandbox_profile_to_string sandbox_profile) );
    ]
  in
  let fields =
    match current_task_id with
    | None -> base_fields
    | Some task_id -> ("current_task_id", `String task_id) :: base_fields
  in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> Alcotest.fail err

let add_task_with_worktree ~config ~repo_dir ~repo_name =
  let _ = Coord.add_task config ~title:"GitHub work" ~priority:1 ~description:"" in
  let backlog = Coord.read_backlog config in
  match backlog.Types.tasks with
  | [] -> Alcotest.fail "expected added task"
  | task :: rest ->
    let updated_task =
      { task with
        worktree =
          Some
            {
              Types.branch = "main";
              path = repo_dir;
              git_root = repo_dir;
              repo_name;
            };
      }
    in
    Coord.write_backlog config
      {
        Types.tasks = updated_task :: rest;
        last_updated = Types.now_iso ();
        version = backlog.version + 1;
      };
    task.id

let with_repo_context_test_env f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  let config = Coord.default_config base in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ignore (Coord.init config ~agent_name:None);
  let repo_dir = Filename.concat base "repo" in
  ensure_dir repo_dir;
  run_argv [ "git"; "-C"; repo_dir; "init"; "-q" ];
  f ~base ~config ~repo_dir

(* ================================================================ *)
(* Read-only subcommands via cmd                                     *)
(* ================================================================ *)

let test_read_only_cmd_prefixes () =
  let read_only_cmds =
    [ "pr list"; "pr list --state open"; "pr view 123";
      "pr diff 123"; "pr checks 123"; "pr status";
      "issue list"; "issue view 456"; "issue status";
      "repo view owner/repo"; "repo list";
      "release list"; "release view v1.0" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "read-only cmd: %s" cmd)
      true
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) read_only_cmds

let test_read_only_case_insensitive () =
  Alcotest.(check bool) "PR LIST uppercase"
    true (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "PR LIST"));
  Alcotest.(check bool) "Pr View mixed"
    true (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "Pr View 123"))

let test_prefixed_gh_command_normalization () =
  Alcotest.(check (option int)) "prefixed gh parser still finds PR number"
    (Some 123)
    (match Keeper_gh_shared.extract_gh_target_number "gh pr view 123" with
     | Some (Keeper_gh_shared.PR, n) -> Some n
     | _ -> None);
  Alcotest.(check (option string)) "prefixed gh parser still finds mutation"
    (Some "pr")
    (match Keeper_gh_shared.gh_mutates_entity "gh pr merge 123" with
     | Some Keeper_gh_shared.PR -> Some "pr"
     | Some Keeper_gh_shared.Issue -> Some "issue"
     | None -> None);
  Alcotest.(check bool) "prefixed gh command stays read-only"
    true
    (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "gh pr list --state open"));
  Alcotest.(check bool) "prefixed gh merge stays mutating"
    true
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "gh pr merge 123"))

let test_parse_simple_gh_command_preserves_quoted_args () =
  match
    Keeper_gh_shared.parse_simple_gh_command
      "pr comment 123 --body 'looks good to me'"
  with
  | Ok cmd ->
    Alcotest.(check (list string)) "quoted arg preserved"
      [ "pr"; "comment"; "123"; "--body"; "looks good to me" ]
      (Keeper_gh_shared.gh_simple_command_argv cmd)
  | Error _ -> Alcotest.fail "expected simple gh command parse"

let test_parse_simple_gh_command_rejects_pipeline () =
  match Keeper_gh_shared.parse_simple_gh_command "pr list | cat" with
  | Error (Keeper_gh_shared.Unsupported_shell_construct "pipeline") -> ()
  | Ok _ -> Alcotest.fail "expected pipeline rejection"
  | Error _ -> Alcotest.fail "expected pipeline rejection tag"

let test_repo_flag_injection_prefixes_args () =
  match Keeper_gh_shared.parse_simple_gh_command "--repo old/repo pr view 123" with
  | Ok cmd ->
    let updated =
      Keeper_gh_shared.gh_simple_command_with_repo_flag
        ~repo_slug:"new/repo" cmd
    in
    Alcotest.(check (list string)) "repo flag injected at front"
      [ "--repo"; "new/repo"; "pr"; "view"; "123" ]
      (Keeper_gh_shared.gh_simple_command_argv updated)
  | Error _ -> Alcotest.fail "expected simple gh command parse"

(* ================================================================ *)
(* Read-only subcommands via args                                    *)
(* ================================================================ *)

let test_read_only_via_args () =
  let read_only_args =
    [ ["pr"; "list"];
      ["pr"; "view"; "123"];
      ["pr"; "diff"; "123"];
      ["issue"; "list"];
      ["issue"; "view"; "456"];
      ["repo"; "view"; "owner/repo"];
      ["release"; "list"] ]
  in
  List.iter (fun args ->
    Alcotest.(check bool)
      (Printf.sprintf "read-only args: [%s]" (String.concat "; " args))
      true
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_args args))
  ) read_only_args

let test_cmd_takes_precedence_over_args () =
  (* When cmd is present and non-empty, args are ignored *)
  Alcotest.(check bool) "cmd=mutating overrides read-only args"
    false
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_cmd_and_args "pr merge 123" ["pr"; "list"]));
  Alcotest.(check bool) "cmd=read-only overrides mutating args"
    true
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_cmd_and_args "pr list" ["pr"; "merge"; "123"]))

(* ================================================================ *)
(* Mutating subcommands                                              *)
(* ================================================================ *)

let test_mutating_cmds_not_read_only () =
  let mutating_cmds =
    [ "pr merge 123"; "pr close 123"; "pr create --title 'fix'";
      "pr edit 123 --title 'new'"; "pr comment 123 --body 'ok'";
      "issue create --title 'bug'"; "issue close 456";
      "issue comment 456 --body 'noted'";
      "gist create file.txt"; "workflow run deploy.yml" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "mutating cmd: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) mutating_cmds

(* ================================================================ *)
(* gh api classification                                             *)
(* ================================================================ *)

let test_api_get_default_is_read_only () =
  let read_only_api =
    [ "api repos/owner/repo/pulls";
      "api repos/owner/repo/pulls/123/comments";
      "api /repos/o/r/issues";
      "api -X GET repos/owner/repo" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api read-only: %s" cmd)
      true
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) read_only_api

let test_api_with_method_flag_is_mutating () =
  let mutating_api =
    [ "api -X POST /repos/o/r/pulls/1/merge";
      "api -X PUT /repos/o/r/pulls/1/merge";
      "api -X PATCH /repos/o/r/pulls/1 -f state=closed";
      "api -X DELETE repos/owner/repo/issues/1";
      "api --method POST /repos/o/r/merges";
      "api --method=POST /repos/o/r/pulls/1/merge";
      "api -x=put /repos/o/r/pulls/1/merge" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api mutating method: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) mutating_api

let test_api_with_field_flag_is_mutating () =
  let field_api =
    [ "api /repos/o/r/pulls/1/merge -f sha=abc123";
      "api /repos/o/r/merges -F base=main -F head=feat";
      "api /repos/o/r/merges --field=base=main" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api field flag mutating: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) field_api

let test_api_graphql_is_mutating () =
  let graphql_cmds =
    [ "api graphql -f query=repository";
      "api graphql -f query=mergePullRequest" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api graphql mutating: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) graphql_cmds

(* ================================================================ *)
(* Edge cases                                                        *)
(* ================================================================ *)

let test_empty_input_not_read_only () =
  (* With op=gh but empty cmd, we cannot classify — treat as mutating. *)
  Alcotest.(check bool) "empty cmd"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd ""));
  Alcotest.(check bool) "whitespace cmd"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "   "));
  Alcotest.(check bool) "empty args"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_args []));
  (* Without op=gh (or any op), keeper_shell falls back to its default
     read-only classification from shard_shell.read_only_tools.
     Tools calling keeper_shell without an op are malformed but harmless
     — they get the safe default. *)
  Alcotest.(check bool) "no op (falls back to default read-only)"
    true (is_ro ~tool_name:"keeper_shell" ~input:(`Assoc []))

let test_non_gh_tool () =
  (* keeper_bash has_mutating_side_effect=true, so it should not be
     classified as read-only even if the cmd looks like a gh read-only cmd *)
  Alcotest.(check bool) "keeper_bash is not affected"
    false
    (is_ro ~tool_name:"keeper_bash" ~input:(mk_cmd "pr list"));
  (* keeper_board_post is mutating (not read-only) but boundary-exempt *)
  Alcotest.(check bool) "keeper_board_post is not read-only"
    false
    (is_ro ~tool_name:"keeper_board_post" ~input:(mk_cmd "pr list"))

let test_api_via_args () =
  Alcotest.(check bool) "api GET via args"
    true
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_args ["api"; "repos/owner/repo/pulls"]));
  Alcotest.(check bool) "api POST via args"
    false
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_args ["api"; "-X"; "POST"; "/repos/o/r/pulls/1/merge"]))

let test_input_aware_mutation_detection () =
  Alcotest.(check bool) "keeper_shell op=gh read-only cmd is not mutating"
    false
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "pr list"));
  Alcotest.(check bool) "keeper_shell op=gh merge cmd is mutating"
    true
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "pr merge 123"));
  Alcotest.(check bool) "masc_code_git status is not mutating"
    false
    (has_side_effect ~tool_name:"masc_code_git" ~input:(mk_action "status"));
  Alcotest.(check bool) "masc_code_git commit is mutating"
    true
    (has_side_effect ~tool_name:"masc_code_git" ~input:(mk_action "commit"))

let test_dangerous_gh_command_classifier () =
  let open Keeper_gh_shared in
  let cases =
    [
      ("repo delete owner/repo", Some "repo delete");
      ("--repo owner/repo repo delete owner/repo", Some "repo delete");
      ("-R owner/repo repo archive owner/repo", Some "repo archive");
      ("--hostname github.example.com repo transfer owner/repo", Some "repo transfer");
      ("auth logout", Some "auth logout");
      ("AUTH TOKEN", Some "auth token");
      ("secret set MY_SECRET", Some "secret set");
      ("ssh-key delete 123", Some "ssh-key delete");
      ("pr merge 123", None);
      ("repo view owner/repo", None);
      ("issue comment 42 --body ok", None);
    ]
  in
  List.iter (fun (cmd, expected) ->
    Alcotest.(check (option string))
      (Printf.sprintf "dangerous classifier: %s" cmd)
      expected
      (gh_dangerous_command cmd)
  ) cases

let test_resolve_task_repo_context_uses_current_task_worktree () =
  with_repo_context_test_env @@ fun ~base:_ ~config ~repo_dir ->
  run_argv
    [ "git"; "-C"; repo_dir; "remote"; "add"; "origin"
    ; "https://github.com/example/project.git"
    ];
  let task_id =
    add_task_with_worktree ~config ~repo_dir ~repo_name:"project"
  in
  let meta = make_meta ~current_task_id:task_id () in
  match Keeper_gh_shared.resolve_task_repo_context ~config ~meta with
  | Ok ctx ->
    Alcotest.(check string) "task id" task_id ctx.task_id;
    Alcotest.(check string) "git root" repo_dir ctx.git_root;
    Alcotest.(check string) "repo slug" "example/project" ctx.repo_slug
  | Error _ -> Alcotest.fail "expected task repo context"

let test_resolve_task_repo_context_reports_missing_worktree () =
  with_repo_context_test_env @@ fun ~base:_ ~config ~repo_dir:_ ->
  let _ = Coord.add_task config ~title:"GitHub work" ~priority:1 ~description:"" in
  let backlog = Coord.read_backlog config in
  let task_id =
    match backlog.Types.tasks with
    | task :: _ -> task.id
    | [] -> Alcotest.fail "expected task"
  in
  let meta = make_meta ~current_task_id:task_id () in
  match Keeper_gh_shared.resolve_task_repo_context ~config ~meta with
  | Error (Keeper_gh_shared.Current_task_missing_worktree missing_task_id) ->
    Alcotest.(check string) "task id" task_id missing_task_id
  | Ok _ -> Alcotest.fail "expected missing worktree error"
  | Error _ -> Alcotest.fail "unexpected repo context error"

let test_resolve_task_repo_context_rejects_non_github_origin () =
  with_repo_context_test_env @@ fun ~base:_ ~config ~repo_dir ->
  run_argv
    [ "git"; "-C"; repo_dir; "remote"; "add"; "origin"
    ; "https://gitlab.com/example/project.git"
    ];
  let task_id =
    add_task_with_worktree ~config ~repo_dir ~repo_name:"project"
  in
  let meta = make_meta ~current_task_id:task_id () in
  match Keeper_gh_shared.resolve_task_repo_context ~config ~meta with
  | Error
      (Keeper_gh_shared.Current_task_origin_not_github
         { task_id = actual_task_id; git_root }) ->
    Alcotest.(check string) "task id" task_id actual_task_id;
    Alcotest.(check string) "git root" repo_dir git_root
  | Ok _ -> Alcotest.fail "expected non-github origin error"
  | Error _ -> Alcotest.fail "unexpected repo context error"

let fake_docker_gh_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation\\n' >&2\n\
  exit 2\n\
fi\n\
workdir=''\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"--workdir\" ]; then\n\
    workdir=\"$2\"\n\
    shift 2\n\
    continue\n\
  fi\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
printf 'docker-gh-ok workdir=%s cmd=%s\\n' \"$workdir\" \"$*\"\n"

let test_keeper_shell_gh_without_current_task_uses_sandbox_context () =
  with_repo_context_test_env @@ fun ~base:_ ~config ~repo_dir ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  let meta = make_meta ~sandbox_profile:Keeper_types.Docker () in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "gh");
            ("cwd", `String repo_dir);
            ("cmd", `String "pr list --repo example/project");
          ])
  in
  let json = Yojson.Safe.from_string raw in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "gh fails through docker route without image" false
    (json |> member "ok" |> to_bool);
  Alcotest.(check string) "sandbox task marker" "(sandbox)"
    (json |> member "task_id" |> to_string);
  Alcotest.(check string) "cwd preserved" repo_dir
    (json |> member "cwd" |> to_string);
  Alcotest.(check bool) "repo omitted when sandbox fallback has none" true
    (json |> member "repo" = `Null);
  Alcotest.(check string) "docker image error surfaced"
    "keeper sandbox docker image is not configured"
    (json |> member "error" |> to_string)

(* Tool-call observability flows through the OAS Event_bus.
   This test verifies a subscriber can receive the equivalent
   signal that MASC-side observers previously emitted. *)
let test_tool_call_observer_via_oas_event_bus () =
  Eio_main.run @@ fun _env ->
  let bus = Agent_sdk.Event_bus.create () in
  let sub =
    Agent_sdk.Event_bus.subscribe
      ~filter:(Agent_sdk.Event_bus.filter_agent "keeper-a")
      bus
  in
  let input = mk_cmd "pr list" in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCalled
          { agent_name = "keeper-a";
            tool_name = "keeper_shell";
            input }));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCompleted
          { agent_name = "keeper-a";
            tool_name = "keeper_shell";
            output = Ok { Agent_sdk.Types.content = "ok" } }));
  let events = Agent_sdk.Event_bus.drain sub in
  Agent_sdk.Event_bus.unsubscribe bus sub;
  Alcotest.(check int) "two tool events received" 2 (List.length events);
  let called =
    List.find_opt
      (fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.ToolCalled _ -> true
        | _ -> false)
      events
  in
  let completed =
    List.find_opt
      (fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.ToolCompleted _ -> true
        | _ -> false)
      events
  in
  (match called with
   | Some { payload = Agent_sdk.Event_bus.ToolCalled
              { agent_name; tool_name; input = observed_input }; _ } ->
       Alcotest.(check string) "agent name" "keeper-a" agent_name;
       Alcotest.(check string) "tool name" "keeper_shell" tool_name;
       Alcotest.(check string) "input payload"
         (Yojson.Safe.to_string input)
         (Yojson.Safe.to_string observed_input)
   | _ -> Alcotest.fail "expected ToolCalled event");
  (match completed with
   | Some { payload = Agent_sdk.Event_bus.ToolCompleted
              { agent_name; tool_name; output }; _ } ->
       Alcotest.(check string) "agent name" "keeper-a" agent_name;
       Alcotest.(check string) "tool name" "keeper_shell" tool_name;
       Alcotest.(check bool) "output is Ok" true (Result.is_ok output)
   | _ -> Alcotest.fail "expected ToolCompleted event")

(* Replicate the Keeper_unified_turn side-effect tracking pattern:
   pair ToolCalled + ToolCompleted (Ok) per tool_name queue, and
   flag committed mutating tools via [has_mutating_side_effect_with_input]. *)
let test_side_effect_tracking_via_event_bus () =
  Eio_main.run @@ fun _env ->
  let bus = Agent_sdk.Event_bus.create () in
  let sub =
    Agent_sdk.Event_bus.subscribe
      ~filter:(Agent_sdk.Event_bus.filter_agent "keeper-a") bus
  in
  let mutating = ref [] in
  let pending : (string, Yojson.Safe.t Queue.t) Hashtbl.t =
    Hashtbl.create 4
  in
  let push_pending tool_name input =
    let q =
      match Hashtbl.find_opt pending tool_name with
      | Some q -> q
      | None ->
          let q = Queue.create () in
          Hashtbl.add pending tool_name q;
          q
    in
    Queue.add input q
  in
  let pop_pending tool_name =
    match Hashtbl.find_opt pending tool_name with
    | Some q when not (Queue.is_empty q) -> Some (Queue.pop q)
    | _ -> None
  in
  let process events =
    List.iter
      (fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.ToolCalled { tool_name; input; _ } ->
            push_pending tool_name input
        | Agent_sdk.Event_bus.ToolCompleted
            { tool_name; output = Ok _; _ } ->
            let input =
              match pop_pending tool_name with
              | Some i -> i
              | None -> `Null
            in
            if Keeper_exec_tools.has_mutating_side_effect_with_input
                 ~tool_name ~input
            then mutating := tool_name :: !mutating
        | Agent_sdk.Event_bus.ToolCompleted
            { tool_name; output = Error _; _ } ->
            let _ = pop_pending tool_name in
            ignore tool_name
        | _ -> ())
      events
  in
  (* A mutating success: keeper_shell gh pr merge *)
  let mut_input =
    `Assoc [ ("op", `String "gh"); ("cmd", `String "pr merge 123") ]
  in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCalled
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            input = mut_input }));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCompleted
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            output = Ok { Agent_sdk.Types.content = "merged" } }));
  (* A read-only success: keeper_shell gh pr list (should NOT be tracked) *)
  let ro_input =
    `Assoc [ ("op", `String "gh"); ("cmd", `String "pr list") ]
  in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCalled
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            input = ro_input }));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCompleted
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            output = Ok { Agent_sdk.Types.content = "list" } }));
  (* A failed mutating call: should NOT be tracked *)
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCalled
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            input = mut_input }));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.mk_event
       (Agent_sdk.Event_bus.ToolCompleted
          { agent_name = "keeper-a"; tool_name = "keeper_shell";
            output = Error { Agent_sdk.Types.message = "boom";
                             recoverable = false; error_class = None } }));
  let events = Agent_sdk.Event_bus.drain sub in
  Agent_sdk.Event_bus.unsubscribe bus sub;
  process events;
  Alcotest.(check (list string))
    "exactly one committed mutating tool (merge)"
    [ "keeper_shell" ] !mutating

(* ================================================================ *)
(* Main-worktree mutation-boundary exemptions                        *)
(* ================================================================ *)

let test_task_claim_is_mutating_but_boundary_exempt () =
  Alcotest.(check bool) "task claim is not read-only"
    false
    (is_ro ~tool_name:"keeper_task_claim" ~input:(`Assoc []));
  Alcotest.(check bool) "task claim bypasses boundary"
    true
    (is_boundary_exempt ~tool_name:"keeper_task_claim" ~input:(`Assoc []))

let test_masc_code_git_write_actions_bypass_boundary () =
  List.iter
    (fun action ->
      Alcotest.(check bool)
        (Printf.sprintf "git %s is mutating" action)
        false
        (is_ro ~tool_name:"masc_code_git" ~input:(mk_action action));
      Alcotest.(check bool)
        (Printf.sprintf "git %s bypasses boundary" action)
        true
        (is_boundary_exempt ~tool_name:"masc_code_git" ~input:(mk_action action)))
    [ "add"; "commit"; "push" ]

let test_keeper_bash_still_opens_boundary () =
  Alcotest.(check bool) "keeper_bash not exempt"
    false
    (is_boundary_exempt ~tool_name:"keeper_bash" ~input:(mk_cmd "git status"))

(* Regression: [masc_] prefix coordination aliases for [keeper_] prefix
   tools were missing from [is_main_worktree_boundary_exempt_with_input]
   in main until #6671, causing masc_improver to hang mid-turn after
   [masc_add_task] opened the boundary and [masc_claim_next] was
   blocked.  Lock the [masc_] and [keeper_] families to the same
   exemption semantics so the next rename does not silently drift. *)
let test_masc_coordination_aliases_bypass_boundary () =
  let check_pair name =
    let expected_ro = Tool_dispatch.is_read_only name in
    Alcotest.(check bool)
      (Printf.sprintf "%s read-only classification" name)
      expected_ro
      (is_ro ~tool_name:name ~input:(`Assoc []));
    Alcotest.(check bool) (name ^ " bypasses boundary") true
      (is_boundary_exempt ~tool_name:name ~input:(`Assoc []))
  in
  List.iter check_pair
    [ "masc_tasks"; "masc_add_task"; "masc_claim_next";
      "masc_batch_add_tasks"; "masc_plan_init"; "masc_plan_set_task";
      "masc_plan_update"; "masc_plan_get"; "masc_transition";
      "masc_broadcast"; "masc_messages"; "masc_status";
      "masc_dashboard"; "masc_agents"; "masc_agent_card";
      "masc_board_post"; "masc_board_comment"; "masc_board_vote";
      "masc_board_comment_vote"; "masc_board_delete";
      "masc_board_list"; "masc_board_get"; "masc_board_stats";
      "masc_board_hearths"; "masc_board_profile" ]

(* Regression: [keeper_board_delete] and [keeper_board_cleanup] were
   missing from the [keeper_*] side of the exempt list even though
   their [masc_*] coordination alias [masc_board_delete] was already
   exempt at line 283 of [keeper_tool_registry.ml].  Observed 2026-04-12
   01:15:25 KST on janitor: the first [keeper_board_delete] of a cleanup
   turn succeeded and opened the mutation boundary, and every subsequent
   [keeper_board_delete] in the same turn was blocked by the
   [pre_tool_use_guard] — burning janitor's turn budget on a repeating
   "tool skipped" loop instead of progressing through the cleanup queue.
   Same structural gap class as #6671 / #6681.

   Board delete and cleanup are MASC-state-only mutations (board post
   store), not main-worktree writes, so multiple deletes per turn are
   safe.  This test locks the exemption so the next rename does not
   silently drift the [keeper_*] side out of sync with [masc_*]. *)
let test_keeper_board_delete_and_cleanup_bypass_boundary () =
  let check name =
    Alcotest.(check bool) (name ^ " is mutating") false
      (is_ro ~tool_name:name ~input:(`Assoc []));
    Alcotest.(check bool) (name ^ " bypasses boundary") true
      (is_boundary_exempt ~tool_name:name ~input:(`Assoc []))
  in
  List.iter check
    [ "keeper_board_delete"; "keeper_board_cleanup" ]

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Keeper github read-only boundary"
    [
      ( "read_only_cmd",
        [
          Alcotest.test_case "read-only cmd prefixes" `Quick
            test_read_only_cmd_prefixes;
          Alcotest.test_case "case insensitive" `Quick
            test_read_only_case_insensitive;
          Alcotest.test_case "prefixed gh command normalization" `Quick
            test_prefixed_gh_command_normalization;
          Alcotest.test_case "simple gh parser preserves quoted args" `Quick
            test_parse_simple_gh_command_preserves_quoted_args;
          Alcotest.test_case "simple gh parser rejects pipeline" `Quick
            test_parse_simple_gh_command_rejects_pipeline;
          Alcotest.test_case "repo flag injection prefixes args" `Quick
            test_repo_flag_injection_prefixes_args;
        ] );
      ( "read_only_args",
        [
          Alcotest.test_case "read-only via args field" `Quick
            test_read_only_via_args;
          Alcotest.test_case "cmd takes precedence over args" `Quick
            test_cmd_takes_precedence_over_args;
        ] );
      ( "mutating_cmds",
        [
          Alcotest.test_case "mutating cmds not read-only" `Quick
            test_mutating_cmds_not_read_only;
        ] );
      ( "gh_api",
        [
          Alcotest.test_case "api GET default is read-only" `Quick
            test_api_get_default_is_read_only;
          Alcotest.test_case "api with -X method is mutating" `Quick
            test_api_with_method_flag_is_mutating;
          Alcotest.test_case "api with -f/-F is mutating" `Quick
            test_api_with_field_flag_is_mutating;
          Alcotest.test_case "api graphql is mutating" `Quick
            test_api_graphql_is_mutating;
        ] );
      ( "edge_cases",
        [
          Alcotest.test_case "empty input not read-only" `Quick
            test_empty_input_not_read_only;
          Alcotest.test_case "non-gh tool" `Quick
            test_non_gh_tool;
          Alcotest.test_case "api via args" `Quick
            test_api_via_args;
          Alcotest.test_case "input-aware mutation detection" `Quick
            test_input_aware_mutation_detection;
          Alcotest.test_case "dangerous gh classifier" `Quick
            test_dangerous_gh_command_classifier;
          Alcotest.test_case "tool observer via OAS event bus" `Quick
            test_tool_call_observer_via_oas_event_bus;
          Alcotest.test_case "side-effect tracking via OAS event bus" `Quick
            test_side_effect_tracking_via_event_bus;
          Alcotest.test_case "task claim mutating but boundary exempt" `Quick
            test_task_claim_is_mutating_but_boundary_exempt;
          Alcotest.test_case "masc_code_git write actions bypass boundary" `Quick
            test_masc_code_git_write_actions_bypass_boundary;
          Alcotest.test_case "keeper_bash still opens boundary" `Quick
            test_keeper_bash_still_opens_boundary;
          Alcotest.test_case "masc_* coordination aliases bypass boundary" `Quick
            test_masc_coordination_aliases_bypass_boundary;
          Alcotest.test_case "keeper_board_delete and cleanup bypass boundary" `Quick
            test_keeper_board_delete_and_cleanup_bypass_boundary;
        ] );
      ( "repo_context",
        [
          Alcotest.test_case "current task worktree resolves repo context"
            `Quick test_resolve_task_repo_context_uses_current_task_worktree;
          Alcotest.test_case "missing worktree is structured error" `Quick
            test_resolve_task_repo_context_reports_missing_worktree;
          Alcotest.test_case "non-github origin is structured error" `Quick
            test_resolve_task_repo_context_rejects_non_github_origin;
          Alcotest.test_case
            "keeper_shell gh without current task uses sandbox context"
            `Quick test_keeper_shell_gh_without_current_task_uses_sandbox_context;
        ] );
    ]
