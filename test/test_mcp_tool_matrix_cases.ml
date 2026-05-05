module Types = Masc_domain

module Mcp_eio = Masc_mcp.Mcp_server_eio
module Config = Masc_mcp.Config

type init_mode =
  | Fresh
  | Init_only
  | Init_joined

type expectation =
  | Expect_success
  | Expect_success_or_guard of string list
  | Expect_guard of string list

type fixture = {
  base_path : string;
  sid : string;
  agent_name : string;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  sw : Eio.Switch.t;
  state : Mcp_eio.server_state;
  worktree_dir : string;
  mutable task_id : string option;
  mutable board_post_id : string option;
  mutable keeper_name : string option;
  mutable verification_id : string option;
  mutable webrtc_offer_id : string option;
  mutable handover_id : string option;
  mutable library_topic : string option;
  mutable worktree_task_id : string option;
  mutable code_file_path : string option;
}

type contract_case = {
  init_mode : init_mode;
  prepare : fixture -> unit;
  arguments : fixture -> Types.tool_schema -> Yojson.Safe.t;
  expectation : expectation;
}

(* Tool inventory derived from Config.raw_all_tool_schemas at test
   initialization (runtime, not link-time). No code generation step needed. *)
let all_known_tool_names =
  Config.raw_all_tool_schemas
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  |> List.sort_uniq String.compare

let strict_success_names =
  [
    "masc_add_task";
    "masc_agent_card";
    "masc_agents";
    "masc_batch_add_tasks";
    "masc_board_comment";
    "masc_board_get";
    "masc_board_list";
    "masc_board_post";
    "masc_board_vote";
    "masc_broadcast";
    "masc_check";
    "masc_claim_next";
    "masc_dashboard";
    "masc_heartbeat";
    "masc_join";
    "masc_keeper_down";
    "masc_keeper_list";
    "masc_leave";
    "masc_library_add";
    "masc_library_list";
    "masc_messages";
    "masc_plan_get";
    "masc_plan_init";
    "masc_plan_set_task";
    "masc_plan_update";
    "masc_start";
    "masc_status";
    "masc_tool_help";
    "masc_transition";
    "masc_transport_status";
    "masc_websocket_discovery";
    "masc_webrtc_answer";
    "masc_webrtc_offer";
    "masc_who";
    "masc_workflow_guide";
    "masc_worktree_create";
    "masc_worktree_list";
    "masc_worktree_remove";
    (* Removed post-pruning:
       masc_init, masc_auth_*, masc_handover_*, masc_verify_* *)
  ]

let strict_guard_cases =
  [
    ("masc_reset", [ "confirm" ]);
  ]

let endpoint_unavailable_guard_names =
  [
    "masc_approve";
    "masc_branch";
    "masc_interrupt";
    "masc_pending_interrupts";
    "masc_reject";
  ]

let endpoint_unavailable_guard_fragments =
  [
    "not available on this MCP endpoint";
  ]

let generic_matrix_excluded_names =
  [
    "masc_keeper_msg";
    "masc_observe_topology";
    "masc_operator_snapshot";
    "masc_policy_status";
    "masc_tool_admin_snapshot";
    "masc_unit_define";
  ]

let string_starts_with ~prefix s =
  let plen = String.length prefix in
  let slen = String.length s in
  slen >= plen && String.sub s 0 plen = prefix

let contains_substring haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if nlen = 0 then
      true
    else if idx + nlen > hlen then
      false
    else if String.sub haystack idx nlen = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let contains_any haystack needles =
  List.exists (fun needle -> contains_substring haystack needle) needles

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

let run_cmd_exn argv =
  let cmd = String.concat " " (List.map Filename.quote argv) in
  match Sys.command cmd with
  | 0 -> ()
  | code ->
      failwith
        (Printf.sprintf "command failed (%d): %s" code cmd)

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
  Mcp_eio.execute_tool_eio ~sw:fixture.sw ~clock:fixture.clock
    ~mcp_session_id:fixture.sid fixture.state ~name ~arguments

let execute_tool_ok fixture ~name ~arguments =
  match execute_tool fixture ~name ~arguments with
  | true, body -> body
  | false, body ->
      failwith (Printf.sprintf "setup tool failed for %s: %s" name body)

let ensure_initialized fixture =
  (* masc_init pruned from registry. Initialise the room state
     directly so downstream masc_join and other tools can work. *)
  ignore
    (Masc_mcp.Coord.init fixture.state.room_config
       ~agent_name:(Some fixture.agent_name))

let ensure_joined fixture =
  match execute_tool fixture ~name:"masc_join"
          ~arguments:
            (`Assoc
              [
                ("agent_name", `String fixture.agent_name);
                ("capabilities", `List [ `String "testing"; `String "tool-matrix" ]);
              ])
  with
  | true, _ -> ()
  | false, body when contains_substring body "already joined" -> ()
  | false, body -> failwith ("masc_join failed: " ^ body)

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
  let fixture =
    {
      base_path;
      sid = "mcp-tool-matrix";
      agent_name = "codex-tool-matrix";
      clock;
      sw;
      state;
      worktree_dir;
      task_id = None;
      board_post_id = None;
      keeper_name = None;
      verification_id = None;
      webrtc_offer_id = None;
      handover_id = None;
      library_topic = None;
      worktree_task_id = None;
      code_file_path = None;
    }
  in
  (match init_mode with
  | Fresh -> ()
  | Init_only -> ensure_initialized fixture
  | Init_joined ->
      ensure_initialized fixture;
      ensure_joined fixture);
  fixture

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
    (execute_tool_ok fixture ~name:"masc_plan_init"
       ~arguments:
         (`Assoc
           [
             ("task_id", `String task_id);
           ]));
  ignore
    (execute_tool_ok fixture ~name:"masc_plan_set_task"
       ~arguments:
         (`Assoc
           [
             ("task_id", `String task_id);
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
        Masc_mcp.Coord.masc_dir fixture.state.room_config
      in
      let req =
        match
          Masc_mcp.Verification.create_request ~base_path
            ~task_id:(ensure_task fixture) ~output:(`String "tool matrix output")
            ~criteria:[] ~worker:"tool-matrix-worker"
            ~verifier:fixture.agent_name ()
        with
        | Ok request -> request
        | Error err ->
            failwith ("failed to seed verification request: " ^ err)
      in
      let req_id = req.id in
      fixture.verification_id <- Some req_id;
      req_id

let ensure_webrtc_offer fixture =
  match fixture.webrtc_offer_id with
  | Some offer_id -> offer_id
  | None ->
      let body =
        execute_tool_ok fixture ~name:"masc_webrtc_offer"
          ~arguments:
            (`Assoc
              [
                ("agent_name", `String fixture.agent_name);
                ("ice_candidates", `List [ `String "candidate:tool-matrix" ]);
              ])
      in
      let offer_id =
        match extract_id body ~fields:[ "offer_id"; "id" ] ~prefixes:[ "offer-" ] with
        | Some value -> value
        | None -> failwith ("failed to parse offer id from: " ^ body)
      in
      fixture.webrtc_offer_id <- Some offer_id;
      offer_id

let ensure_handover _fixture =
  (* masc_handover_create pruned from registry. Helper retained as a
     stub for any transitional callers; returns a synthetic id. *)
  "handover-pruned-stub"

let ensure_library_topic fixture =
  match fixture.library_topic with
  | Some topic -> topic
  | None ->
      mkdir_p (Filename.concat fixture.base_path "me/docs/library");
      mkdir_p (Filename.concat fixture.base_path "me/docs/library/candidates");
      ignore
        (execute_tool_ok fixture ~name:"masc_library_add"
           ~arguments:
             (`Assoc
               [
                 ("title", `String "Tool Matrix Library");
                 ("content", `String "knowledge");
                 ("source", `String "direct_experience");
                 ("confidence", `Float 0.9);
                 ("tags", `List [ `String "tool-matrix" ]);
               ]));
      fixture.library_topic <- Some "tool-matrix-library";
      "tool-matrix-library"

(* Ensure the keeper's playground has a git clone before calling
   masc_worktree_create. After PRs #6533/#6542 removed the server-root
   fallback, keepers must clone into
   .masc/playground/<agent>/repos/<repo>/ first. This helper clones
   the fixture's local bare remote into the playground repos
   directory and is idempotent.

   The [agent] parameter overrides [fixture.agent_name] for cases
   where a different keeper identity is used at runtime (e.g. the
   keeper tool matrix, whose runtime keeper meta name differs from
   the generic fixture agent name). *)
let ensure_playground_clone_for ?agent fixture =
  let agent_name = match agent with Some n -> n | None -> fixture.agent_name in
  let playground_repos =
    Filename.concat fixture.base_path
      (Printf.sprintf ".masc/playground/%s/repos" agent_name)
  in
  let clone_target = Filename.concat playground_repos "tool-matrix" in
  if not (Sys.file_exists clone_target) then begin
    mkdir_p playground_repos;
    let remote_dir = Filename.concat fixture.base_path ".remote.git" in
    run_cmd_exn [ "git"; "clone"; "-q"; remote_dir; clone_target ];
    run_cmd_exn
      [ "git"; "-C"; clone_target; "config"; "user.email"; "tool-matrix@example.test" ];
    run_cmd_exn
      [ "git"; "-C"; clone_target; "config"; "user.name"; "Tool Matrix" ]
  end;
  clone_target

let ensure_playground_clone fixture = ensure_playground_clone_for fixture

(* Create a worktree for a specific agent name (defaults to
   [fixture.agent_name]). Takes [?agent] so the keeper tool matrix can
   create the worktree under the real keeper meta name instead of the
   generic fixture agent, keeping create and remove paths consistent. *)
let ensure_worktree_created_for ?agent fixture =
  let agent_name = match agent with Some n -> n | None -> fixture.agent_name in
  match fixture.worktree_task_id with
  | Some task_id -> task_id
  | None ->
      let task_id = ensure_task fixture in
      let _ = ensure_playground_clone_for ?agent fixture in
      ignore
        (execute_tool_ok fixture ~name:"masc_worktree_create"
           ~arguments:
             (`Assoc
               [
                 ("agent_name", `String agent_name);
                 ("task_id", `String task_id);
                 ("base_branch", `String "main");
               ]));
      fixture.worktree_task_id <- Some task_id;
      task_id

let ensure_worktree_created fixture = ensure_worktree_created_for fixture

let ensure_code_file fixture =
  match fixture.code_file_path with
  | Some path -> path
  | None ->
      let relative_path = ".worktrees/editor/sample.txt" in
      let absolute_path = Filename.concat fixture.base_path relative_path in
      write_text_file absolute_path "before\n";
      fixture.code_file_path <- Some relative_path;
      relative_path

let ensure_lock fixture =
  ignore
    (execute_tool_ok fixture ~name:"masc_lock"
       ~arguments:
         (`Assoc
           [
             ("agent_name", `String fixture.agent_name);
             ("file", `String "README.md");
           ]))

let prepare_for_name fixture name =
  if List.mem name [ "masc_claim_next"; "masc_transition"; "masc_plan_set_task" ] then
    ignore (ensure_task fixture);
  if List.mem name [ "masc_plan_get"; "masc_plan_update"; "masc_plan_get_task"; "masc_plan_clear_task" ] then
    ensure_plan_initialized fixture;
  if List.mem name [ "masc_board_get"; "masc_board_comment"; "masc_board_vote"; "masc_board_comment_vote"; "masc_board_delete" ] then
    ignore (ensure_board_post fixture);
  (* masc_verify_* tools pruned from registry; no preparation needed. *)
  if name = "masc_webrtc_answer" then
    ignore (ensure_webrtc_offer fixture);
  if List.mem name [ "masc_worktree_create"; "masc_worktree_list" ] then
    ignore (ensure_playground_clone fixture);
  if name = "masc_worktree_remove" then
    ignore (ensure_worktree_created fixture);
  if List.mem name [ "masc_code_edit"; "masc_code_delete"; "masc_code_git"; "masc_code_shell"; "masc_code_read"; "masc_code_symbols" ] then
    ignore (ensure_code_file fixture);
  if name = "masc_library_add" then begin
    mkdir_p (Filename.concat fixture.base_path "me/docs/library");
    mkdir_p (Filename.concat fixture.base_path "me/docs/library/candidates")
  end;
  if List.mem name [ "masc_library_list"; "masc_library_read"; "masc_library_promote"; "masc_library_search" ] then
    ignore (ensure_library_topic fixture);
  (* masc_handover_* tools pruned from registry; no preparation needed. *)
  let _ = ensure_handover in
  if name = "masc_unlock" then
    ensure_lock fixture

let required_fields schema =
  match assoc_field "required" schema.Types.input_schema with
  | Some (`List values) ->
      values
      |> List.filter_map (function `String value -> Some value | _ -> None)
  | _ -> []

let property_schema schema field =
  match assoc_field "properties" schema.Types.input_schema with
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

let field_value fixture ~tool_name field_name schema =
  let enum_choice = enum_first schema in
  match field_name with
  | "agent_name" | "author" | "owner" | "worker" | "agent" | "leader_id" ->
      `String fixture.agent_name
  | "path" when tool_name = "masc_set_room" || tool_name = "masc_start" ->
      `String fixture.base_path
  | "path" when List.mem tool_name [ "masc_code_write"; "masc_code_edit"; "masc_code_delete"; "masc_code_read"; "masc_code_symbols" ] ->
      `String (ensure_code_file fixture)
  | "working_dir"
    when tool_name = "masc_keeper_repair" ->
      `String fixture.worktree_dir
  | "cwd" -> `String fixture.worktree_dir
  | "command" -> `String "git status"
  | "content" when tool_name = "masc_code_write" -> `String "after\n"
  | "content" -> `String "tool matrix content"
  | "old_string" -> `String "before"
  | "new_string" -> `String "after"
  | "key" -> `String "tool-matrix-cache"
  | "task_id" -> `String (task_id_for_tool fixture tool_name)
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
            ];
        ]
  | "post_id" | "parent_id" -> `String (ensure_board_post fixture)
  | "name"
    when
      List.mem tool_name
        [
          "masc_keeper_up";
          "masc_keeper_repair";
        ] ->
      `String "bad keeper!"
  | "task_spec" when tool_name = "masc_keeper_repair" ->
      `String "Write only OCaml code for inc : int -> int."
  | "source_text" when tool_name = "masc_keeper_repair" ->
      `String "let inc n = n + 1\n"
  | "name" when tool_name = "masc_keeper_msg" ->
      `String "bad keeper!"
  | "name" -> `String "tool-matrix"
  | "verification_id" -> `String (ensure_verification_request fixture)
  | "verifier" -> `String fixture.agent_name
  | "verdict" -> `String "pass"
  | "score" -> `Float 0.9
  | "timeout_sec" when tool_name = "masc_keeper_msg" ->
      `Float 1.0
  | "timeout" when tool_name = "masc_listen" -> `Int 1
  | "interval" when tool_name = "masc_heartbeat_start" -> `Int 5
  | "offer_id" -> `String (ensure_webrtc_offer fixture)
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
  | "horizon" -> `String "short"
  | "mode" -> (
      match enum_choice with
      | Some value -> `String value
      | None -> `String "manual")
  | "action" when tool_name = "masc_code_git" -> `String "status"
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
  | "include_deprecated" -> `Bool true
  | "include_usage" -> `Bool true
  | "hearth" -> `String "tool-matrix"
  | "query" -> `String "tool matrix"
  | "search" -> `String "tool matrix"
  | "prompt" -> `String "tool matrix"
  | "topic_id" -> `String "topic-001"
  | "room_id" -> `String "default"
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

let tool_arguments fixture (schema : Types.tool_schema) =
  let name = schema.Types.name in
  let fields =
    let required = required_fields schema in
    let optional =
      match name with
      | "masc_start" -> [ "path"; "task_title" ]
      | "masc_worktree_create" -> [ "base_branch" ]
      | "masc_heartbeat_start" -> [ "interval" ]
      | "masc_keeper_repair" ->
          [ "source_text"; "max_attempts"; "working_dir" ]
      | "masc_keeper_msg" ->
          [ "timeout_sec" ]
      | "masc_board_post" ->
          (* Schema no longer requires content|author (both are validated at
             the handler layer so body/content aliases both work). Matrix
             test still needs to supply body so board_core accepts it. *)
          [ "body" ]
      | _ -> []
    in
    List.sort_uniq String.compare (required @ optional)
  in
  `Assoc
    (List.map
       (fun field ->
         (field, field_value fixture ~tool_name:name field (property_schema schema field)))
       fields)

let provider_guard_fragments =
  [
    "api key";
    "not configured";
    "runtime unavailable";
    "provider";
    "unsupported";
    "unavailable";
    "connection refused";
    "failed to connect";
    "no runtime";
    "spawn error";
    "no such file";
  ]

let state_guard_fragments =
  [
    "not found";
    "missing";
    "required";
    "invalid";
    "must be";
    "join required";
    "room not initialized";
    "already exists";
    "no active";
    "unknown";
    "not a member";
    "no document matching";
  ]

let git_guard_fragments =
  [
    "not a git repository";
    "worktree";
    "origin/";
    "file not found";
    "allowlist";
    "restricted";
    "blocked";
    "path traversal";
  ]

let web_search_guard_fragments =
  [
    "curl exit code";
    "curl signal";
    "curl stopped";
    "search endpoint returned no http status";
    "search endpoint returned http";
    "search endpoint returned a non-rss payload";
  ]

let guard_fragments_for_name name =
  if String.equal name "masc_web_search" then
    web_search_guard_fragments
  else if
    List.exists
      (fun prefix -> string_starts_with ~prefix name)
      [
        "masc_a2a_";
        "masc_autoresearch_";
        "masc_handover_";
        "masc_keeper_";
        "masc_local_runtime_";
        "masc_relay_";
        "masc_repo_synthesis_";
        "masc_runtime_";
        "masc_spawn";

        "masc_voice_";
      ]
  then
    provider_guard_fragments @ state_guard_fragments
  else if
    List.exists
      (fun prefix -> string_starts_with ~prefix name)
      [ "masc_code_"; "masc_worktree_" ]
  then
    git_guard_fragments @ state_guard_fragments
  else
    state_guard_fragments @ git_guard_fragments

let case_for_name name =
  let init_mode =
    match name with
    | "masc_init" | "masc_start" | "masc_set_room" -> Fresh
    | "masc_join" -> Init_only
    | _ -> Init_joined
  in
  let prepare fixture = prepare_for_name fixture name in
  let expectation =
    match List.assoc_opt name strict_guard_cases with
    | Some fragments -> Expect_guard fragments
    | None ->
        if List.mem name strict_success_names then
          Expect_success
        else if List.mem name endpoint_unavailable_guard_names then
          Expect_guard endpoint_unavailable_guard_fragments
        else if List.mem name all_known_tool_names then
          Expect_success_or_guard (guard_fragments_for_name name)
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

let fatal_fragments =
  [
    "tool timed out after";
    "internal error";
    "dispatch_v2 handler error";
    "unknown tool";
    "tools/call timeout";
  ]

let evaluate_expectation ~name expectation response =
  let text = response_text response in
  let is_error = response_is_error response in
  if contains_any text fatal_fragments then
    Error
      (Printf.sprintf "%s hit fatal tool-host failure: %s" name text)
  else
    match expectation with
    | Expect_success ->
        if is_error then
          Error (Printf.sprintf "%s expected success but got error: %s" name text)
        else
          Ok ()
    | Expect_guard fragments ->
        if is_error && contains_any text fragments then
          Ok ()
        else if is_error then
          Error
            (Printf.sprintf "%s expected guard %s but got: %s" name
               (String.concat ", " fragments) text)
        else
          Error (Printf.sprintf "%s expected guard but succeeded" name)
    | Expect_success_or_guard fragments ->
        if (not is_error) || contains_any text fragments then
          Ok ()
        else
          Error
            (Printf.sprintf "%s expected success or guard %s but got: %s" name
               (String.concat ", " fragments) text)

let call_tool_json fixture (schema : Types.tool_schema) arguments =
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
                ("name", `String schema.Types.name);
                ("arguments", arguments);
              ] );
        ])
  in
  Mcp_eio.handle_request ~clock:fixture.clock ~sw:fixture.sw
    ~mcp_session_id:fixture.sid fixture.state request

let run_case sw ~proc_mgr ~fs ~net ~mono_clock clock
    (schema : Types.tool_schema) =
  let saved_home = Sys.getenv_opt "HOME" in
  let saved_env =
    [
      ("MASC_BASE_PATH", Sys.getenv_opt "MASC_BASE_PATH");
      ("MASC_STORAGE_TYPE", Sys.getenv_opt "MASC_STORAGE_TYPE");
      ("MASC_POSTGRES_URL", Sys.getenv_opt "MASC_POSTGRES_URL");
      ("DATABASE_URL", Sys.getenv_opt "DATABASE_URL");
      ("SUPABASE_DB_URL", Sys.getenv_opt "SUPABASE_DB_URL");
      ("SB_PG_URL", Sys.getenv_opt "SB_PG_URL");
    ]
  in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "DATABASE_URL" "";
  Unix.putenv "SUPABASE_DB_URL" "";
  Unix.putenv "SB_PG_URL" "";
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
        match saved_home with
        | Some home -> Unix.putenv "HOME" home
        | None -> Unix.putenv "HOME" "")
      (fun () ->
        Unix.putenv "HOME" base_path;
        try
          let case = case_for_name schema.Types.name in
          let fixture =
            make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path
              case.init_mode
          in
          case.prepare fixture;
          let arguments = case.arguments fixture schema in
          let response = call_tool_json fixture schema arguments in
          if String.equal schema.Types.name "masc_heartbeat_start" then
            Heartbeat.list ()
            |> List.iter (fun hb -> ignore (Heartbeat.stop hb.Heartbeat.id));
          evaluate_expectation ~name:schema.Types.name case.expectation response
        with exn ->
          Error
            (Printf.sprintf "%s raised during contract execution: %s"
               schema.Types.name (Printexc.to_string exn)))
  in
  (base_path, result)
