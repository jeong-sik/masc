(** Tests for keeper_pr_workflow validation gates.

    Covers:
    1. Required field validation (branch, file_path, commit_message, pr_title)
    2. Preset gate (social/research → rejected, delivery/coding/full → accepted)
    3. Branch name sanitization (reject shell metacharacters)
    4. Worktree step failure propagation (no remote → clean error)

    Does NOT test: actual git push / gh pr create (requires real remote).
    Those are covered by the safety gate in test_keeper_github_safety.ml. *)

open Alcotest
open Masc_mcp

let make_meta_with_preset preset_str =
  match Keeper_types.meta_of_json
    (`Assoc
      [ "name", `String "test-keeper"
      ; "agent_name", `String "test-keeper"
      ; "trace_id", `String "test-trace-pr"
      ; "tool_access", `Assoc
          [ "kind", `String "preset"
          ; "preset", `String preset_str
          ; "also_allow", `List []
          ]
      ]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta_with_preset('%s') failed: %s" preset_str e)

let make_ctx_work () =
  Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let policy_init_once = lazy (
  (* Load tool_policy.toml from the repo root so presets resolve correctly.
     The repo root is derived by walking up from the test executable's location. *)
  let repo_root =
    let cwd = Sys.getcwd () in
    (* dune runs tests from the repo root *)
    if Sys.file_exists (Filename.concat cwd "config/tool_policy.toml")
    then cwd
    else
      (* fallback: try parent dirs *)
      let rec go d =
        if d = "/" then failwith "cannot find config/tool_policy.toml"
        else if Sys.file_exists (Filename.concat d "config/tool_policy.toml")
        then d
        else go (Filename.dirname d)
      in
      go (Filename.dirname cwd)
  in
  Keeper_exec_tools.init_policy_config ~base_path:repo_root
)

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Lazy.force policy_init_once;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_pr_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match saved_pg with
       | Some v -> Unix.putenv "MASC_POSTGRES_URL" v
       | None -> (try Unix.putenv "MASC_POSTGRES_URL" "" with _ -> ()));
      (match saved_sb with
       | Some v -> Unix.putenv "SB_PG_URL" v
       | None -> (try Unix.putenv "SB_PG_URL" "" with _ -> ()));
      (try
        let rec rm path =
          if Sys.is_directory path then begin
            Sys.readdir path |> Array.iter (fun f ->
              rm (Filename.concat path f));
            Unix.rmdir path
          end else
            Sys.remove path
        in
        rm dir
      with _ -> ()))
    (fun () ->
      let config = Room.default_config dir in
      let _msg = Room.init config ~agent_name:(Some "test-keeper") in
      f config)

let call_tool config meta name input =
  let ctx_work = make_ctx_work () in
  Keeper_exec_tools.execute_keeper_tool_call
    ~config ~meta ~ctx_work ~name ~input ()

let parse_json s =
  try Yojson.Safe.from_string s
  with _ -> failwith (Printf.sprintf "invalid JSON: %s" s)

let json_string key json =
  Yojson.Safe.Util.(member key json |> to_string)

let json_bool key json =
  Yojson.Safe.Util.(member key json |> to_bool)

(* --- Required field validation --- *)

let valid_pr_args =
  `Assoc
    [ "branch", `String "test-branch"
    ; "file_path", `String "src/test.ml"
    ; "file_content", `String "let x = 1"
    ; "commit_message", `String "test commit"
    ; "pr_title", `String "Test PR"
    ]

let test_missing_branch () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String ""
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_required"
      "branch_required" (json_string "error" json))

let test_missing_file_path () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String ""
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is file_path_required"
      "file_path_required" (json_string "error" json))

let test_missing_commit_message () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String ""
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is commit_message_required"
      "commit_message_required" (json_string "error" json))

let test_missing_pr_title () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String ""
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is pr_title_required"
      "pr_title_required" (json_string "error" json))

(* --- Preset gate --- *)

(* Preset rejection can happen at two layers:
   1. Tool policy layer: tool_not_allowed (tool not in preset's allowed list)
   2. Function-level: preset_insufficient (inside handle_keeper_pr_workflow)
   Either indicates correct rejection. *)
let is_rejected json =
  let error = try json_string "error" json with _ -> "" in
  let ok = try json_bool "ok" json with _ -> false in
  (not ok) && (error = "tool_not_allowed" || error = "preset_insufficient")

let test_social_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "social" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "social preset rejected" true (is_rejected json))

let test_research_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "research" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "research preset rejected" true (is_rejected json))

let test_minimal_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "minimal" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "minimal preset rejected" true (is_rejected json))

let test_delivery_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    (* Delivery passes preset gate. Fails at worktree step since test room
       is not a git repo, but that means validation passed. *)
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

let test_coding_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "coding" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

let test_full_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "full" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

(* --- Branch name sanitization --- *)

let test_branch_with_semicolon_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test;rm -rf /"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_pipe_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test|cat /etc/passwd"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_backtick_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test`whoami`"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_dot_dot_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "../../etc/passwd"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_space_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_dollar_paren_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test$(whoami)"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_branch_with_ampersand_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test&&echo pwned"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    check string "error is branch_contains_invalid_chars"
      "branch_contains_invalid_chars" (json_string "error" json))

let test_valid_branch_with_slash_accepted () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "feature/my-branch_123"
      ; "file_path", `String "src/test.ml"
      ; "file_content", `String "let x = 1"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let error = json_string "error" json in
    (* Should pass branch validation, fail at worktree step *)
    check bool "error is NOT branch_contains_invalid_chars"
      true (error <> "branch_contains_invalid_chars"))

(* --- Worktree step failure propagation --- *)

let test_worktree_failure_propagates () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    (* Test room is not a git repo, so worktree_create fails.
       The result should be ok=false with a meaningful error. *)
    check bool "ok is false" false (json_bool "ok" json);
    let steps = json_string "steps" json in
    check bool "steps contains worktree_create"
      true (try ignore (Str.search_forward
        (Str.regexp_string "worktree_create") steps 0); true
        with Not_found -> false);
    let error = json_string "error" json in
    check bool "error mentions worktree"
      true (try ignore (Str.search_forward
        (Str.regexp_string "worktree") (String.lowercase_ascii error) 0); true
        with Not_found -> false))

(* --- Task lifecycle: claim → done --- *)

let test_task_claim_then_done_lifecycle () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    (* Add a task *)
    let _ = Room.add_task config ~title:"Lifecycle test" ~priority:1 ~description:"test" in
    (* Claim it — response is {"result": "string"} *)
    let claim_result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let claim_json = parse_json claim_result in
    let result_str = json_string "result" claim_json in
    check bool "claim returns non-empty result" true (String.length result_str > 0);
    (* Extract task_id from result string *)
    let task_id =
      let re_task = Re.(compile (seq [str "task-"; rep1 (alt [digit; char '-'])])) in
      let re_t = Re.(compile (seq [char 'T'; char '-'; rep1 digit])) in
      match Re.exec_opt re_task result_str with
      | Some g -> Re.Group.get g 0
      | None ->
        match Re.exec_opt re_t result_str with
        | Some g -> Re.Group.get g 0
        | None -> failwith (Printf.sprintf "cannot extract task_id from: %s" result_str)
    in
    (* Mark it done — response is {"ok": bool, "result": "string"} *)
    let done_result = call_tool config meta "keeper_task_done"
      (`Assoc [("task_id", `String task_id);
               ("result", `String "completed by lifecycle test")]) in
    let done_json = parse_json done_result in
    let done_ok = try json_bool "ok" done_json with _ -> false in
    check bool "done succeeds" true done_ok)

(* --- Task duplicate claim prevention --- *)

let test_second_claim_on_single_task_returns_no_tasks () =
  with_room (fun config ->
    let meta_a = make_meta_with_preset "delivery" in
    let meta_b =
      match Keeper_types.meta_of_json
        (`Assoc
          [ "name", `String "other-keeper"
          ; "agent_name", `String "other-keeper"
          ; "trace_id", `String "test-trace-other"
          ; "tool_access", `Assoc
              [ "kind", `String "preset"
              ; "preset", `String "delivery"
              ; "also_allow", `List []
              ]
          ]) with
      | Ok m -> m
      | Error e -> failwith e
    in
    (* Add exactly one task *)
    let _ = Room.add_task config ~title:"Single task" ~priority:1 ~description:"test" in
    (* Keeper A claims it *)
    let _ = call_tool config meta_a "keeper_task_claim" (`Assoc []) in
    (* Keeper B tries to claim — response is {"result": "string"} *)
    let result_b = call_tool config meta_b "keeper_task_claim" (`Assoc []) in
    let json_b = parse_json result_b in
    let result_str = json_string "result" json_b in
    (* The result should indicate no unclaimed tasks available *)
    let lower = String.lowercase_ascii result_str in
    check bool "second claim indicates no unclaimed tasks"
      true (try ignore (Str.search_forward
        (Str.regexp_string "no unclaimed") lower 0); true
        with Not_found ->
          try ignore (Str.search_forward
            (Str.regexp_string "nothing to claim") lower 0); true
          with Not_found ->
            try ignore (Str.search_forward
              (Str.regexp_string "no tasks") lower 0); true
            with Not_found -> false))

let () =
  run "keeper_pr_workflow"
    [ "required_fields",
      [ test_case "missing branch" `Quick test_missing_branch
      ; test_case "missing file_path" `Quick test_missing_file_path
      ; test_case "missing commit_message" `Quick test_missing_commit_message
      ; test_case "missing pr_title" `Quick test_missing_pr_title
      ]
    ; "preset_gate",
      [ test_case "social rejected" `Quick test_social_preset_rejected
      ; test_case "research rejected" `Quick test_research_preset_rejected
      ; test_case "minimal rejected" `Quick test_minimal_preset_rejected
      ; test_case "delivery passes" `Quick test_delivery_preset_passes_validation
      ; test_case "coding passes" `Quick test_coding_preset_passes_validation
      ; test_case "full passes" `Quick test_full_preset_passes_validation
      ]
    ; "branch_sanitization",
      [ test_case "semicolon rejected" `Quick test_branch_with_semicolon_rejected
      ; test_case "pipe rejected" `Quick test_branch_with_pipe_rejected
      ; test_case "backtick rejected" `Quick test_branch_with_backtick_rejected
      ; test_case "dot-dot rejected" `Quick test_branch_with_dot_dot_rejected
      ; test_case "space rejected" `Quick test_branch_with_space_rejected
      ; test_case "dollar-paren rejected" `Quick test_branch_with_dollar_paren_rejected
      ; test_case "ampersand rejected" `Quick test_branch_with_ampersand_rejected
      ; test_case "slash accepted" `Quick test_valid_branch_with_slash_accepted
      ]
    ; "step_propagation",
      [ test_case "worktree failure" `Quick test_worktree_failure_propagates
      ]
    ; "task_lifecycle",
      [ test_case "claim then done" `Quick test_task_claim_then_done_lifecycle
      ]
    ; "task_dedup",
      [ test_case "second claim no tasks" `Quick test_second_claim_on_single_task_returns_no_tasks
      ]
    ]
