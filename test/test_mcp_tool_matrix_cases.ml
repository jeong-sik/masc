module Types = Masc_domain

module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server
module Config = Masc.Config
module Goal_store = Goal_store

type init_mode =
  | Fresh
  | Init_only
  | Init_joined

(* Whether a tool that refused did so on purpose.

   Every [Tool_result.error] carries a typed [tool_failure_class] -- it is a
   required argument, so no refusal can omit it -- and the MCP envelope puts
   it on the wire under the call's [_meta] entry. Reading that is the
   whole check.

   It replaced a list of ~20 substrings ("not found", "missing", "invalid",
   "must be", ...) matched against the rendered response. Two things were
   wrong with that. A crash whose text happened to contain one of the words
   passed as a graceful refusal, which is a false green in the one test whose
   job is catching crashes. And every new tool's author had to guess which
   words their rejection was allowed to use -- 2026-08-26 took main red
   exactly that way, over the word "registered".

   Exhaustive on purpose: a sixth failure class has to be called graceful or
   not right here, and the compiler asks. A substring list could never ask. *)
let is_graceful_refusal = function
  | Tool_result.Dependency_unavailable
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection
  | Tool_result.Operator_cancelled -> true
  | Tool_result.Runtime_failure -> false

type expectation =
  | Expect_success
  | Expect_success_or_refusal
      (** Called with default arguments, this tool may do the work or refuse
          it. Either is a contract; falling over is not. *)
  | Expect_refusal
      (** Called this way the tool must refuse. Succeeding means the guard
          this case exists to prove is not running. *)
  | Expect_refusal_saying of string
      (** One tool, one exact message. Used where the case proves a specific
          validation fires, not merely that something refused. *)

type fixture = {
  base_path : string;
  sid : string;
  agent_name : string;
  auth_token : string;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  sw : Eio.Switch.t;
  state : Mcp_eio.server_state;
  worktree_dir : string;
  mutable task_id : string option;
  mutable board_post_id : string option;
  mutable keeper_name : string option;
  mutable verification_id : string option;
  mutable handover_id : string option;
  mutable library_topic : string option;
  mutable code_file_path : string option;
  mutable goal_id : string option;
}

type contract_case = {
  init_mode : init_mode;
  prepare : fixture -> unit;
  arguments : fixture -> Masc_domain.tool_schema -> Yojson.Safe.t;
  expectation : expectation;
}

(* Tool inventory derived from Config.raw_all_tool_schemas at test
   initialization (runtime, not link-time). No code generation step needed. *)
let all_known_tool_names =
  Config.raw_all_tool_schemas
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  |> List.sort_uniq String.compare

let strict_success_names =
  [
    "masc_add_task";
    "masc_agent_card";
    "masc_batch_add_tasks";
    "masc_board_comment";
    "masc_board_get";
    "masc_board_list";
    "masc_board_post";
    "masc_board_vote";
    "masc_broadcast";
    "masc_check";

    "masc_dashboard";
    "masc_heartbeat";
    "masc_keeper_down";
    "masc_keeper_list";
    "masc_library_add";
    "masc_library_list";
    "masc_messages";
    "masc_plan_set_task";
    "masc_start";
    "masc_status";
    "masc_tool_help";
    "masc_transition";
    "masc_transport_status";
    "masc_websocket_discovery";
    "masc_workflow_guide";
    (* Removed post-pruning:
       masc_init, masc_auth_*, masc_handover_*, masc_verify_* *)
  ]

let strict_message_cases =
  [
    (* The runner plumbs sw/clock (RFC-0182 Phase 5 PR-A.2), so the dispatch
       no longer stops at the "requires Eio context" gate: the deliberately
       invalid target name ("bad keeper!") must be rejected by argument
       validation. *)
    ("masc_keeper_delegate", "keeper_name must match");
  ]

let must_refuse_names =
  [
    "masc_approve";
    "masc_branch";
    "masc_interrupt";
    "masc_pending_interrupts";
    "masc_reject";
    "masc_operator_snapshot";
  ]

let generic_matrix_excluded_names =
  []

let string_starts_with ~prefix s =
  let plen = String.length prefix in
  let slen = String.length s in
  slen >= plen && String.sub s 0 plen = prefix

let contains_any haystack needles =
  List.exists
    (fun needle -> String_util.contains_substring_ci haystack needle)
    needles

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string_field field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let parse_json_from_text text =
  try Some (Yojson.Safe.from_string text)
  with Yojson.Json_error _ -> (
    try
      let idx = String.index text '{' in
      Some
        (Yojson.Safe.from_string
           (String.sub text idx (String.length text - idx)))
    with Not_found | Yojson.Json_error _ -> None)

let extract_prefixed_token text prefixes =
  let allowed = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '/' -> true
    | _ -> false
  in
  let len = String.length text in
  let scan_prefix prefix start =
    let plen = String.length prefix in
    let rec loop idx =
      if idx + plen > len then
        None
      else if String.sub text idx plen = prefix then
        let j = ref (idx + plen) in
        while !j < len && allowed text.[!j] do
          incr j
        done;
        Some (String.sub text idx (!j - idx))
      else
        loop (idx + 1)
    in
    loop start
  in
  let rec find = function
    | [] -> None
    | prefix :: rest -> (
        match scan_prefix prefix 0 with
        | Some value -> Some value
        | None -> find rest)
  in
  find prefixes

let extract_id text ~fields ~prefixes =
  match parse_json_from_text text with
  | Some json -> (
      match List.find_map (fun field -> json_string_field field json) fields with
      | Some _ as value -> value
      | None -> extract_prefixed_token text prefixes)
  | None -> extract_prefixed_token text prefixes

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let cleanup_dir = rm_rf

let rec mkdir_p path =
  if path = "" || path = Filename.dir_sep || Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

(* Must equal the keeper registry's normalized identity for the keeper
   fixture registered in [make_fixture]. The auth token and dispatch context
   use this identity for tools that require an authenticated actor. *)
let tool_matrix_agent_name = "tool-matrix"

let rec waitpid_nointr pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid
;;

let seed_keeper_config base_path agent_name =
  let keepers_dir =
    Filename.concat
      (Filename.concat (Filename.concat base_path ".masc") "config")
      "keepers"
  in
  let agent_dir = Filename.concat keepers_dir agent_name in
  mkdir_p agent_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (agent_name ^ ".toml"))
    "[keeper]\nautoboot_enabled = true\ninstructions = \"Run the tool matrix.\"\n";
  Config_dir_resolver.reset ()

let run_cmd_exn argv =
  let code =
    match argv with
    | [] -> invalid_arg "run_cmd_exn: empty argv"
    | prog :: _ ->
        let dev_null = Unix.openfile Filename.null [ Unix.O_WRONLY ] 0o600 in
        Fun.protect
          ~finally:(fun () -> Unix.close dev_null)
          (fun () ->
            let pid =
              Unix.create_process_env prog (Array.of_list argv)
                (Unix.environment ()) Unix.stdin dev_null dev_null
            in
            match snd (waitpid_nointr pid) with
            | Unix.WEXITED code -> code
            | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255)
  in
  match code with
  | 0 -> ()
  | code ->
      failwith
        (Printf.sprintf "command failed (%d): %s" code (String.concat " " argv))

let write_text_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let setup_git_repo base_path =
  let readme = Filename.concat base_path "README.md" in
  let remote_dir = Filename.concat base_path ".remote.git" in
  write_text_file readme "# tool-matrix\n";
  run_cmd_exn [ "git"; "init"; "-b"; "main"; base_path ];
  run_cmd_exn [ "git"; "-C"; base_path; "config"; "user.email"; "tool-matrix@example.test" ];
  run_cmd_exn [ "git"; "-C"; base_path; "config"; "user.name"; "Tool Matrix" ];
  run_cmd_exn [ "git"; "-C"; base_path; "add"; "README.md" ];
  run_cmd_exn [ "git"; "-C"; base_path; "commit"; "-m"; "init" ];
  run_cmd_exn [ "git"; "init"; "--bare"; remote_dir ];
  run_cmd_exn [ "git"; "-C"; base_path; "remote"; "add"; "origin"; remote_dir ];
  run_cmd_exn [ "git"; "-C"; base_path; "push"; "-u"; "origin"; "main" ];
  run_cmd_exn [ "git"; "-C"; base_path; "fetch"; "origin" ];
  let sandbox_dir = Filename.concat base_path ".worktrees/editor" in
  run_cmd_exn
    [ "git"; "-C"; base_path; "worktree"; "add"; sandbox_dir; "-b"; "matrix/editor"; "main" ];
  sandbox_dir

let execute_tool fixture ~name ~arguments =
  Mcp_eio.execute_tool_eio
    ~sw:fixture.sw
    ~clock:fixture.clock
    ~workspace_scope:(Mcp_server.workspace_scope fixture.state)
    ~auth_token:fixture.auth_token
    ~mcp_session_id:fixture.sid fixture.state ~name ~arguments

let execute_tool_ok fixture ~name ~arguments =
  let result = execute_tool fixture ~name ~arguments in
  if (Tool_result.is_success result) then (Tool_result.message result)
  else failwith (Printf.sprintf "setup tool failed for %s: %s" name ((Tool_result.message result)))

let ensure_initialized fixture =
  (* masc_init pruned from registry. Initialise the workspace state directly so
     downstream tools can work. *)
  ignore
    (Masc.Workspace.init (Mcp_server.workspace_config fixture.state)
       ~agent_name:(Some fixture.agent_name))

let ensure_bound fixture =
  let result =
    execute_tool fixture ~name:"masc_start"
      ~arguments:
        (`Assoc
          [
            ("path", `String fixture.base_path);
          ])
  in
  if (Tool_result.is_success result) then ()
  else begin
    let body = (Tool_result.message result) in
    if String_util.contains_substring_ci body "already joined" then ()
    else failwith ("masc_start failed: " ^ body)
  end

let make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path init_mode =
  let worktree_dir = setup_git_repo base_path in
  Fs_compat.set_fs fs;
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Eio_context.set_mono_clock mono_clock;
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  let state =
    Mcp_eio.create_state_eio ~sw ~proc_mgr ~fs ~clock ~mono_clock ~net
      ~base_path
  in
  (* The matrix models a fully booted server: tools behind the startup gate
     (e.g. masc_keeper_up) must see [state_ready], exactly as after the
     production bootstrap publishes readiness. *)
  (match Masc.Server_startup_state.mark_state_ready () with
  | Ok () -> ()
  | Error err ->
      failwith (Masc.Server_startup_state.state_ready_error_to_string err));
  seed_keeper_config base_path tool_matrix_agent_name;
  let auth_token =
    match
      Auth.create_token base_path ~agent_name:tool_matrix_agent_name
        ~role:Masc_domain.Admin
    with
    | Ok (token, _cred) -> token
    | Error err ->
        failwith
          ("failed to create tool matrix auth token: "
          ^ Masc_domain.masc_error_to_string err)
  in
  let fixture =
    {
      base_path;
      sid = "mcp-tool-matrix";
      agent_name = tool_matrix_agent_name;
      auth_token;
      clock;
      sw;
      state;
      worktree_dir;
      task_id = None;
      board_post_id = None;
      keeper_name = None;
      verification_id = None;
      handover_id = None;
      library_topic = None;
      code_file_path = None;
      goal_id = None;
    }
  in
  (match init_mode with
  | Fresh -> ()
  | Init_only -> ensure_initialized fixture
  | Init_joined ->
      ensure_initialized fixture;
      ensure_bound fixture);
  fixture

let ensure_goal fixture =
  match fixture.goal_id with
  | Some goal_id -> goal_id
  | None ->
      let goal =
        match
          Goal_store.upsert_goal (Mcp_server.workspace_config fixture.state)
            ~title:"Tool Matrix Goal" ~metric:"m" ~target_value:"1" ()
        with
        | Ok (goal, _status) -> goal
        | Error err -> failwith ("failed to seed tool matrix goal: " ^ err)
      in
      fixture.goal_id <- Some goal.Goal_store.id;
      goal.Goal_store.id

let ensure_task fixture =
  match fixture.task_id with
  | Some task_id -> task_id
  | None ->
      let body =
        execute_tool_ok fixture ~name:"masc_add_task"
          ~arguments:
            (`Assoc
              [
                ("title", `String "Tool Matrix Task");
                ("priority", `Int 2);
                ("description", `String "task fixture");
                ("goal_id", `String (ensure_goal fixture));
              ])
      in
      let task_id =
        match extract_id body ~fields:[ "task_id"; "id" ] ~prefixes:[ "task-" ] with
        | Some value -> value
        | None -> failwith ("failed to parse task id from: " ^ body)
      in
      fixture.task_id <- Some task_id;
      task_id

let ensure_plan_initialized fixture =
  let task_id = ensure_task fixture in
  ignore
    (execute_tool_ok fixture ~name:"masc_plan_set_task"
       ~arguments:
         (`Assoc
           [
             ("task_id", `String task_id);
           ]))

let ensure_run_initialized fixture =
  let task_id = ensure_task fixture in
  ignore
    (execute_tool_ok fixture ~name:"masc_run_init"
       ~arguments:
         (`Assoc
           [
             ("task_id", `String task_id);
             ("agent_name", `String fixture.agent_name);
           ]))

let ensure_board_post fixture =
  match fixture.board_post_id with
  | Some post_id -> post_id
  | None ->
      let body =
        execute_tool_ok fixture ~name:"masc_board_post"
          ~arguments:
            (`Assoc
              [
                ("author", `String fixture.agent_name);
                ("title", `String "Tool Matrix Post");
                ("content", `String "tool-matrix-post");
                ("visibility", `String "internal");
              ])
      in
      let post_id =
        match extract_id body ~fields:[ "id"; "post_id" ] ~prefixes:[ "post-" ] with
        | Some value -> value
        | None -> failwith ("failed to parse post id from: " ^ body)
      in
      fixture.board_post_id <- Some post_id;
      post_id

let ensure_verification_request fixture =
  match fixture.verification_id with
  | Some req_id -> req_id
  | None ->
      let base_path =
        Masc.Workspace.masc_dir (Mcp_server.workspace_config fixture.state)
      in
      let req =
        match
          Masc.Verification.create_request ~base_path
            ~task_id:(ensure_task fixture) ~output:(`String "tool matrix output")
            ~criteria:[] ~worker:"tool-matrix-worker"
            ()
        with
        | Ok request -> request
        | Error err ->
            failwith ("failed to seed verification request: " ^ err)
      in
      let req_id = req.id in
      fixture.verification_id <- Some req_id;
      req_id

let ensure_handover _fixture =
  (* masc_handover_create pruned from registry. Helper retained as a
     stub for any transitional callers; returns a synthetic id. *)
  "handover-pruned-stub"

let ensure_library_topic fixture =
  match fixture.library_topic with
  | Some topic -> topic
  | None ->
      mkdir_p (Filename.concat fixture.base_path "docs/library");
      ignore
        (execute_tool_ok fixture ~name:"masc_library_add"
           ~arguments:
             (`Assoc
               [
                 ("title", `String "Tool Matrix Library");
                 ("content", `String "knowledge");
                 ("source", `String "direct_experience");
                 ("tags", `List [ `String "tool-matrix" ]);
               ]));
      fixture.library_topic <- Some "tool-matrix-library";
      "tool-matrix-library"

let ensure_code_file fixture =
  match fixture.code_file_path with
  | Some path -> path
  | None ->
      let relative_path = ".worktrees/editor/sample.txt" in
      let absolute_path = Filename.concat fixture.base_path relative_path in
      write_text_file absolute_path "before\n";
      fixture.code_file_path <- Some relative_path;
      relative_path

let prepare_for_name fixture name =
  if List.mem name [ "keeper_task_claim"; "masc_transition"; "masc_plan_set_task" ] then
    ignore (ensure_task fixture);
  if List.mem name [ "masc_plan_get_task"; "masc_plan_clear_task" ] then
    ensure_plan_initialized fixture;
  if name = "masc_run_plan" then
    ensure_run_initialized fixture;
  if List.mem name [ "masc_board_get"; "masc_board_comment"; "masc_board_vote"; "masc_board_comment_vote"; "masc_board_delete" ] then
    ignore (ensure_board_post fixture);
  (* masc_verify_* tools pruned from registry; no preparation needed. *)
  if
    List.mem name
      [
        "tool_edit_file";
        "tool_write_file";
        "tool_read_file";
        "tool_search_files";
      ]
  then
    ignore (ensure_code_file fixture);
  if name = "masc_get_metrics" then begin
    (* The read contract needs at least one recorded metric for the calling
       agent; an empty store answers with a not_found rejection instead. *)
    let now = Unix.gettimeofday () in
    Masc.Metrics_store_eio.record
      (Mcp_server.workspace_config fixture.state)
      {
        Masc.Metrics_store_eio.id = Masc.Metrics_store_eio.generate_id ();
        agent_id = fixture.agent_name;
        task_id = "tool-matrix-metric";
        started_at = now;
        completed_at = Some now;
        success = true;
        error_message = None;
        collaborators = [];
        handoff_from = None;
        handoff_to = None;
      }
  end;
  if name = "masc_task_set_goal" then begin
    (* masc_task_set_goal links goalless tasks only (RFC-0267 Phase 2), but
       [ensure_task] creates its task already linked to the fixture goal.
       Seed a goalless task first so the shared task-id cache serves it. *)
    let body =
      execute_tool_ok fixture ~name:"masc_add_task"
        ~arguments:
          (`Assoc
            [
              ("title", `String "Tool Matrix Goalless Task");
              ("priority", `Int 2);
              ("description", `String "goalless task fixture");
            ])
    in
    match extract_id body ~fields:[ "task_id"; "id" ] ~prefixes:[ "task-" ] with
    | Some task_id -> fixture.task_id <- Some task_id
    | None -> failwith ("failed to parse goalless task id from: " ^ body)
  end;
  if name = "masc_library_add" then
    mkdir_p (Filename.concat fixture.base_path "docs/library");
  if List.mem name [ "masc_library_list"; "masc_library_read"; "masc_library_search" ] then
    ignore (ensure_library_topic fixture);
  (* masc_handover_* tools pruned from registry; no preparation needed. *)
  let _ = ensure_handover in
  ()

let required_fields schema =
  match assoc_field "required" schema.Masc_domain.input_schema with
  | Some (`List values) ->
      values
      |> List.filter_map (function `String value -> Some value | _ -> None)
  | _ -> []

let property_schema schema field =
  match assoc_field "properties" schema.Masc_domain.input_schema with
  | Some (`Assoc props) -> List.assoc_opt field props
  | _ -> None

let enum_first = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "enum" fields with
      | Some (`List (`String value :: _)) -> Some value
      | _ -> None)
  | _ -> None

let field_type = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "type" fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let task_id_for_tool fixture _tool_name = ensure_task fixture

let goal_principal fixture =
  `Assoc
    [
      ("kind", `String "agent");
      ("id", `String fixture.agent_name);
    ]

let field_value fixture ~tool_name field_name schema =
  let enum_choice = enum_first schema in
  match field_name with
  | "agent_name" | "author" | "owner" | "worker" | "agent" | "leader_id" ->
      `String fixture.agent_name
  | "path" when tool_name = "masc_set_workspace" || tool_name = "masc_start" ->
      `String fixture.base_path
  | "path"
    when List.mem tool_name
           [
             "tool_write_file";
             "tool_edit_file";
             "tool_read_file";
             "tool_search_files";
           ] ->
      `String (ensure_code_file fixture)
  | "working_dir" -> `String fixture.worktree_dir
  | "cwd" -> `String fixture.worktree_dir
  | "command" -> `String "git status"
  | "content" when tool_name = "tool_write_file" -> `String "after\n"
  | "content" -> `String "tool matrix content"
  | "old_string" -> `String "before"
  | "new_string" -> `String "after"
  | "key" -> `String "tool-matrix-cache"
  | "task_id" -> `String (task_id_for_tool fixture tool_name)
  | "goal_id" -> `String (ensure_goal fixture)
  | "actor" | "principal" -> goal_principal fixture
  | "task_title" -> `String "Tool Matrix Started Task"
  | "title" -> `String "Tool Matrix Title"
  | "summary" -> `String "tool matrix summary"
  | "description" -> `String "tool matrix description"
  | "message" -> `String "tool matrix message"
  | "goal" when tool_name = "masc_bounded_run" ->
      `Assoc
        [
          ("path", `String "$.done");
          ("condition", `Assoc [ ("eq", `Bool true) ]);
        ]
  | "goal" -> `String "tool matrix goal"
  | "progress" -> `String "tool matrix progress"
  | "reason" when tool_name = "masc_handover_create" -> `String "explicit"
  | "notes" | "note" | "reason" -> `String "tool matrix note"
  | "priority" -> `Int 2
  | "assertions" -> `List [ `String "joined" ]
  | "agents" -> `List [ `String "definitely-missing-agent" ]
  | "capabilities" -> `List [ `String "testing"; `String "tool-matrix" ]
  | "tasks" ->
      `List
        [
          `Assoc
            [
              ("title", `String "Tool Matrix Batch Task");
              ("priority", `Int 2);
              ("description", `String "batch");
              ("goal_id", `String (ensure_goal fixture));
            ];
        ]
  | "post_id" | "parent_id" -> `String (ensure_board_post fixture)
  | "name"
    when
      List.mem tool_name
        [
          "masc_keeper_up";
        ] ->
      `String "bad keeper!"
  | "target" when tool_name = "masc_keeper_delegate" ->
      `Assoc [ "kind", `String "keeper"; "name", `String "bad keeper!" ]
  | "run_ref"
    when List.mem tool_name
           [ "masc_keeper_delegate_status"; "masc_keeper_delegate_cancel" ] ->
      `Assoc
        [ "run_id", `String "missing-run"
        ; "target", `Assoc [ "kind", `String "keeper"; "name", `String "tool-matrix" ]
        ; "capability", `String "invoke_turn"
        ]
  | "name" -> `String "tool-matrix"
  | "verification_id" -> `String (ensure_verification_request fixture)
  | "verifier" -> `String fixture.agent_name
  | "verdict" -> `String "pass"
  | "score" -> `Float 0.9
  | "timeout" when tool_name = "masc_listen" -> `Int 1
  | "interval" when tool_name = "masc_heartbeat_start" -> `Int 5
  | "ice_candidates" -> `List [ `String "candidate:tool-matrix" ]
  | "tool_name" -> `String "masc_status"
  | "subscription_id" -> `String "subscription-001"
  | "events" -> `List [ `String "agent.joined" ]
  | "worker_name" -> `String "tool-matrix-worker"
  | "tool_names" -> `List [ `String "masc_status" ]
  | "decision_reason" -> `String "tool matrix reason"
  | "decision_confidence" -> `Float 0.9
  | "output" -> `String "tool matrix output"
  | "criteria" -> `List []
  | "topic" -> `String (ensure_library_topic fixture)
  | "include_candidates" -> `Bool true
  | "mode" -> (
      match enum_choice with
      | Some value -> `String value
      | None -> `String "manual")
  | "action" -> (
      match enum_choice with
      | Some value -> `String value
      | None -> `String "claim")
  | "args" -> `List []
  | "visibility" -> `String "internal"
  | "ttl_hours" -> `Int 24
  | "limit" -> `Int 5
  | "offset" -> `Int 0
  | "since_seq" -> `Int 0
  | "include_hidden" -> `Bool true
  | "include_usage" -> `Bool true
  | "hearth" -> `String "tool-matrix"
  | "query" -> `String "tool matrix"
  | "search" -> `String "tool matrix"
  | "prompt" -> `String "tool matrix"
  | "topic_id" -> `String "topic-001"
  | "workspace_id" -> `String "default"
  | "checkpoint_ref" -> `String "checkpoint-001"
  | "intent_id" -> `String "intent-001"
  | "operation_id" -> `String "operation-001"
  | "unit_id" -> `String "unit-001"
  | "assigned_unit_id" -> `String "unit-001"
  | "parent_unit_id" -> `String "company-tool-matrix"
  | "workload_profile" | "workload_template" | "policy_class" | "budget_class"
  | "status" | "state" -> (
      match enum_choice with
      | Some value -> `String value
      | None -> `String "active")
  | "objective" -> `String "tool matrix objective"
  | "invariants" | "artifact_priors" | "roster" | "capability_profile"
  | "active_goal_ids" | "depends_on_operation_ids" ->
      `List [ `String "tool-matrix-item" ]
  | "success_metric" | "current_focus" | "policy" | "budget" | "chain_input"
  | "meta" ->
      `Assoc []
  | "to_agent" -> `String "peer-agent"
  | "thread_id" -> `String "thread-001"
  | "confirm" -> `Bool false
  | "files" | "channels" -> `List []
  | "bpm" -> `Int 120
  | "param" -> `String "volume"
  | "value" -> `Float 0.5
  | "replace_all" | "create_dirs" | "dry_run" | "force" | "clear" ->
      `Bool true
  | "time" | "step" -> `Int 1
  | "float" -> `Float 0.5
  | _ -> (
      match field_type schema, enum_choice with
      | _, Some value -> `String value
      | Some "integer", _ -> `Int 1
      | Some "number", _ -> `Float 1.0
      | Some "boolean", _ -> `Bool true
      | Some "array", _ -> `List []
      | Some "object", _ -> `Assoc []
      | _ -> `String "tool-matrix")

let tool_arguments fixture (schema : Masc_domain.tool_schema) =
  let name = schema.Masc_domain.name in
  let fields =
    let required = required_fields schema in
    let optional =
      match name with
      | "masc_start" -> [ "path"; "task_title" ]
      | "masc_heartbeat_start" -> [ "interval" ]
      | "masc_board_post" ->
          (* The schema declares [content] as the field the handler layer
             validates; the strict field gate (#33565) rejects anything else,
             so the matrix fixture must supply [content]. *)
          [ "content" ]
      | "masc_board_post_update" ->
          (* Same as masc_board_post: [content] is optional in the schema,
             but the matrix fixture must supply a non-empty [content] or the
             handler rejects the edit. *)
          [ "content" ]
      | "masc_goal_transition" -> [ "note" ]
      | _ -> []
    in
    List.sort_uniq String.compare (required @ optional)
  in
  `Assoc
    (List.map
       (fun field ->
         (field, field_value fixture ~tool_name:name field (property_schema schema field)))
       fields)

let case_for_name name =
  let init_mode =
    match name with
    | "masc_init" | "masc_start" | "masc_set_workspace" -> Fresh
    | _ -> Init_joined
  in
  let prepare fixture = prepare_for_name fixture name in
  let expectation =
    match List.assoc_opt name strict_message_cases with
    | Some message -> Expect_refusal_saying message
    | None ->
        if List.mem name strict_success_names then
          Expect_success
        else if List.mem name must_refuse_names then
          Expect_refusal
        else if List.mem name all_known_tool_names then
          Expect_success_or_refusal
        else
          failwith ("missing contract for " ^ name)
  in
  { init_mode; prepare; arguments = (fun fixture schema -> tool_arguments fixture schema); expectation }

let render_response_json response = Yojson.Safe.to_string response

let response_text response =
  let pieces =
    match response with
    | `Assoc fields -> (
        let result_text =
          match List.assoc_opt "result" fields with
          | Some (`Assoc result_fields) -> (
              match List.assoc_opt "content" result_fields with
              | Some (`List content) ->
                  content
                  |> List.filter_map (function
                       | `Assoc text_fields -> (
                           match List.assoc_opt "text" text_fields with
                           | Some (`String value) -> Some value
                           | _ -> None)
                       | _ -> None)
              | _ -> [])
          | _ -> []
        in
        let error_text =
          match List.assoc_opt "error" fields with
          | Some (`Assoc error_fields) -> (
              match List.assoc_opt "message" error_fields with
              | Some (`String value) -> [ value ]
              | _ -> [])
          | _ -> []
        in
        result_text @ error_text)
    | _ -> []
  in
  String.concat "\n" (pieces @ [ render_response_json response ])

let response_is_error = function
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Null) | None -> (
          match List.assoc_opt "result" fields with
          | Some (`Assoc result_fields) -> (
              match List.assoc_opt "isError" result_fields with
              | Some (`Bool value) -> value
              | _ -> false)
          | _ -> true)
      | Some _ -> true)
  | _ -> true

(* Host-level failures, which never reach a tool and so never carry a class:
   the dispatcher did not find the tool, or the call timed out above it. These
   stay textual because there is no typed value to read -- the tool never ran.
   Everything a tool itself decides is read from [failure_class] below. *)
let host_failure_fragments =
  [
    "tool timed out after";
    "dispatch_v2 handler error";
    "unknown tool";
    "tools/call timeout";
  ]

(* The class the tool set, read back from the call's [_meta] entry.
   [None] means the response carried no class: either it succeeded, or the
   envelope shape changed under us. The caller distinguishes those. *)
let response_failure_class response =
  let meta_field fields name =
    match List.assoc_opt name fields with Some value -> Some value | None -> None
  in
  match response with
  | `Assoc fields -> (
      match meta_field fields "result" with
      | Some (`Assoc result_fields) -> (
          match meta_field result_fields "_meta" with
          | Some (`Assoc meta_fields) -> (
              match meta_field meta_fields Masc.Mcp_server.tool_call_meta_key with
              | Some (`Assoc call_fields) -> (
                  match meta_field call_fields "failure_class" with
                  | Some (`String raw) ->
                    Tool_result.tool_failure_class_of_string raw
                  | Some _ | None -> None)
              | Some _ | None -> None)
          | Some _ | None -> None)
      | Some _ | None -> None)
  | _ -> None

let refusal_class_report = function
  | None -> "no failure_class on the response"
  | Some class_ -> Tool_result.tool_failure_class_to_string class_

let evaluate_expectation ~name expectation response =
  let text = response_text response in
  let is_error = response_is_error response in
  let failure_class = response_failure_class response in
  let refused_gracefully =
    match failure_class with Some class_ -> is_graceful_refusal class_ | None -> false
  in
  if contains_any text host_failure_fragments then
    Error (Printf.sprintf "%s hit fatal tool-host failure: %s" name text)
  else
    match expectation with
    | Expect_success ->
        if is_error then
          Error (Printf.sprintf "%s expected success but got error: %s" name text)
        else
          Ok ()
    | Expect_refusal ->
        if not is_error then
          Error (Printf.sprintf "%s expected a refusal but succeeded" name)
        else if refused_gracefully then
          Ok ()
        else
          Error
            (Printf.sprintf "%s refused with %s, which is a fault rather than a guard: %s"
               name (refusal_class_report failure_class) text)
    | Expect_refusal_saying expected ->
        if not is_error then
          Error (Printf.sprintf "%s expected a refusal but succeeded" name)
        else if not refused_gracefully then
          Error
            (Printf.sprintf "%s refused with %s, which is a fault rather than a guard: %s"
               name (refusal_class_report failure_class) text)
        else if contains_any text [ expected ] then
          Ok ()
        else
          Error
            (Printf.sprintf "%s refused as expected but did not say %S: %s" name expected text)
    | Expect_success_or_refusal ->
        if (not is_error) || refused_gracefully then
          Ok ()
        else
          Error
            (Printf.sprintf "%s neither succeeded nor refused -- %s: %s" name
               (refusal_class_report failure_class) text)

let call_tool_json fixture (schema : Masc_domain.tool_schema) arguments =
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 7001);
          ("method", `String "tools/call");
          ( "params",
            `Assoc
              [
                ("name", `String schema.Masc_domain.name);
                ("arguments", arguments);
              ] );
        ])
  in
  Mcp_eio.handle_request ~clock:fixture.clock ~sw:fixture.sw
    ~mcp_session_id:fixture.sid ~auth_token:fixture.auth_token fixture.state
    request

let run_case sw ~proc_mgr ~fs ~net ~mono_clock clock
    (schema : Masc_domain.tool_schema) =
  let saved_home = Sys.getenv_opt "HOME" in
	  let saved_env =
	    [
	      ("MASC_BASE_PATH", Sys.getenv_opt "MASC_BASE_PATH");
	    ]
	  in
	  let base_path = temp_dir "mcp-tool-matrix-" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let result =
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (name, value) ->
            match value with
            | Some raw -> Unix.putenv name raw
            | None -> Unix.putenv name "")
          saved_env;
        Config_dir_resolver.reset ();
        match saved_home with
        | Some home -> Unix.putenv "HOME" home
        | None -> Unix.putenv "HOME" "")
      (fun () ->
        Unix.putenv "HOME" base_path;
        try
          let case = case_for_name schema.Masc_domain.name in
          let fixture =
            make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path
              case.init_mode
          in
          case.prepare fixture;
          let arguments = case.arguments fixture schema in
          let response = call_tool_json fixture schema arguments in
          if String.equal schema.Masc_domain.name "masc_heartbeat_start" then
            Heartbeat.list ()
            |> List.iter (fun hb -> ignore (Heartbeat.stop hb.Heartbeat.id));
          evaluate_expectation ~name:schema.Masc_domain.name case.expectation response
        with exn ->
          Error
            (Printf.sprintf "%s raised during contract execution: %s"
               schema.Masc_domain.name (Printexc.to_string exn)))
  in
  (base_path, result)

(* Regression: contains_any must match fatal/guard fragments case-insensitively.
   PR #28206 replaced the local lowercasing helper with a byte-wise
   case-sensitive contains_substring; contains_any now uses
   String_util.contains_substring_ci so mixed-case responses such as
   "Internal Error" or "Already joined" still match the lowercase fragments. *)
let test_mixed_case_contains_any () =
  let assert_matches haystack needle =
    if not (contains_any haystack [ needle ]) then
      failwith
        (Printf.sprintf "contains_any should match %S against %S" needle haystack)
  in
  let assert_not_matches haystack needle =
    if contains_any haystack [ needle ] then
      failwith
        (Printf.sprintf "contains_any should NOT match %S against %S" needle haystack)
  in
  (* fatal fragments *)
  assert_matches "Internal Error" "internal error";
  assert_matches "internal error" "internal error";
  assert_matches "TOOL TIMED OUT AFTER 30s" "tool timed out after";
  assert_matches "Unknown Tool" "unknown tool";
  (* guard fragments *)
  assert_matches "Already Joined" "already joined";
  assert_matches "Not Available on this MCP endpoint" "not available on this MCP endpoint";
  (* negative: distinct text must not match *)
  assert_not_matches "internal success" "internal error";
  assert_not_matches "already done" "already joined";
  ()

let () =
  test_mixed_case_contains_any ()
