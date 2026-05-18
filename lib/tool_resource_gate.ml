(** Tool_resource_gate — bounded local tool lanes for active Keeper fleets.

    This is intentionally separate from {!Admission_queue}.  OAS/provider
    capacity still belongs to the cascade layer; this module only protects
    host-local MCP tool bottlenecks that a 24-Keeper burst can stampede:
    shell subprocesses, GitHub/gh calls, Docker, filesystem scans/writes,
    board/coordination JSONL writes, and web I/O. *)

type resource_class =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
  | Filesystem_write
  | Board_write
  | Coordination_write
  | Web
  | Generic_write

type gate =
  { resource_class : resource_class
  ; label : string
  ; env_var : string
  ; limit : int
  ; semaphore : Eio.Semaphore.t
  ; waiting : int Atomic.t
  ; acquired_total : int Atomic.t
  ; rejected_total : int Atomic.t
  }

type gates =
  { shell : gate
  ; github : gate
  ; docker : gate
  ; filesystem_read : gate
  ; filesystem_write : gate
  ; board_write : gate
  ; coordination_write : gate
  ; web : gate
  ; generic_write : gate
  }

let env_bool ?(default = false) name =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
    (match String.lowercase_ascii (String.trim raw) with
     | "1" | "true" | "yes" | "on" -> true
     | "0" | "false" | "no" | "off" -> false
     | _ -> default)
;;

let env_int ?(min_v = 1) name default =
  match Sys.getenv_opt name with
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some n -> max min_v n
     | None -> default)
  | None -> default
;;

let env_float ?(min_v = 0.001) name default =
  match Sys.getenv_opt name with
  | Some raw ->
    (match float_of_string_opt (String.trim raw) with
     | Some n -> max min_v n
     | None -> default)
  | None -> default
;;

let label_of_resource_class = function
  | Ungated -> "ungated"
  | Shell -> "shell"
  | Github -> "github"
  | Docker -> "docker"
  | Filesystem_read -> "filesystem_read"
  | Filesystem_write -> "filesystem_write"
  | Board_write -> "board_write"
  | Coordination_write -> "coordination_write"
  | Web -> "web"
  | Generic_write -> "generic_write"
;;

let resource_class_to_string = label_of_resource_class

let make_gate resource_class env_var default_limit =
  let limit = env_int env_var default_limit in
  { resource_class
  ; label = label_of_resource_class resource_class
  ; env_var
  ; limit
  ; semaphore = Eio.Semaphore.make limit
  ; waiting = Atomic.make 0
  ; acquired_total = Atomic.make 0
  ; rejected_total = Atomic.make 0
  }
;;

let make_gates () =
  { shell = make_gate Shell "MASC_TOOL_GATE_SHELL_MAX" 8
  ; github = make_gate Github "MASC_TOOL_GATE_GITHUB_MAX" 4
  ; docker = make_gate Docker "MASC_TOOL_GATE_DOCKER_MAX" 2
  ; filesystem_read = make_gate Filesystem_read "MASC_TOOL_GATE_FS_READ_MAX" 12
  ; filesystem_write = make_gate Filesystem_write "MASC_TOOL_GATE_FS_WRITE_MAX" 6
  ; board_write = make_gate Board_write "MASC_TOOL_GATE_BOARD_WRITE_MAX" 8
  ; coordination_write =
      make_gate Coordination_write "MASC_TOOL_GATE_COORD_WRITE_MAX" 12
  ; web = make_gate Web "MASC_TOOL_GATE_WEB_MAX" 6
  ; generic_write = make_gate Generic_write "MASC_TOOL_GATE_GENERIC_WRITE_MAX" 12
  }
;;

let gates_ref = ref (make_gates ())

let gate_for_class = function
  | Ungated -> None
  | Shell -> Some (!gates_ref).shell
  | Github -> Some (!gates_ref).github
  | Docker -> Some (!gates_ref).docker
  | Filesystem_read -> Some (!gates_ref).filesystem_read
  | Filesystem_write -> Some (!gates_ref).filesystem_write
  | Board_write -> Some (!gates_ref).board_write
  | Coordination_write -> Some (!gates_ref).coordination_write
  | Web -> Some (!gates_ref).web
  | Generic_write -> Some (!gates_ref).generic_write
;;

let all_gates () =
  let g = !gates_ref in
  [ g.shell
  ; g.github
  ; g.docker
  ; g.filesystem_read
  ; g.filesystem_write
  ; g.board_write
  ; g.coordination_write
  ; g.web
  ; g.generic_write
  ]
;;

let enabled () = not (env_bool "MASC_TOOL_RESOURCE_GATE_DISABLED")
let wait_timeout_sec () = env_float "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" 20.0

let json_string_opt key json = Safe_ops.json_string_opt key json

let string_contains haystack needle =
  String_util.contains_substring_ci haystack needle
;;

let command_mentions_docker cmd =
  let cmd = String.lowercase_ascii cmd in
  String.equal (String.trim cmd) "docker"
  || string_contains cmd "docker "
  || string_contains cmd " docker"
  || string_contains cmd "docker-compose"
;;

let command_mentions_github cmd =
  let cmd = String.lowercase_ascii cmd in
  string_contains cmd "gh "
  || String.starts_with ~prefix:"gh " (String.trim cmd)
  || string_contains cmd " git clone"
  || String.starts_with ~prefix:"git clone" (String.trim cmd)
  || string_contains cmd " git fetch"
  || String.starts_with ~prefix:"git fetch" (String.trim cmd)
  || string_contains cmd " git pull"
  || String.starts_with ~prefix:"git pull" (String.trim cmd)
  || string_contains cmd " git push"
  || String.starts_with ~prefix:"git push" (String.trim cmd)
;;

type keeper_shell_op_classification =
  | Known_shell_op of resource_class
  | Unknown_shell_op of string

let classify_keeper_shell_op_value raw =
  match String.lowercase_ascii (String.trim raw) with
  | "gh" | "git_clone" -> Known_shell_op Github
  | "git_worktree" -> Known_shell_op Filesystem_write
  | "git_status" | "git_log" | "git_diff" -> Known_shell_op Filesystem_read
  | "rg" | "find" | "tree" | "cat" | "head" | "tail" | "wc" | "ls" ->
    Known_shell_op Filesystem_read
  | "bash" | "exec" | "shell" | "sh" -> Known_shell_op Shell
  | unknown -> Unknown_shell_op unknown
;;

let classify_keeper_shell_op args =
  match json_string_opt "op" args with
  | Some raw ->
    (match classify_keeper_shell_op_value raw with
     | Known_shell_op resource_class -> resource_class
     | Unknown_shell_op unknown ->
       Log.Mcp.warn
         "unknown keeper_shell op; defaulting resource gate to shell: op=%s"
         unknown;
       Shell)
  | None -> Shell
;;

let classify_keeper_tool (tool : Tool_name.Keeper.t) args =
  let open Tool_name.Keeper in
  match tool with
  | Tool_name.Keeper.Bash ->
    let cmd = Option.value ~default:"" (json_string_opt "cmd" args) in
    if command_mentions_docker cmd then Docker
    else if command_mentions_github cmd then Github
    else Shell
  | Bash_kill | Bash_output -> Ungated
  | Shell -> classify_keeper_shell_op args
  | Pr_create | Pr_list | Pr_review_comment | Pr_review_read | Pr_review_reply | Pr_status ->
    Github
  | Preflight_check -> Shell
  | Fs_edit | Write -> Filesystem_write
  | Fs_read | Code_read | Tool_search -> Filesystem_read
  | Memory_write | Handoff -> Filesystem_write
  | Memory_search | Library_read | Library_search -> Filesystem_read
  | Board_post
  | Board_comment
  | Board_comment_vote
  | Board_curation_submit
  | Board_delete
  | Board_cleanup
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_update
  | Board_vote -> Board_write
  | Task_claim
  | Task_create
  | Task_done
  | Task_submit_for_verification
  | Task_force_done
  | Task_force_release -> Coordination_write
  | Broadcast | Voice_agent | Voice_listen | Voice_session_start | Voice_speak -> Generic_write
  | Board_curation_read
  | Board_get
  | Board_list
  | Board_search
  | Board_stats
  | Board_sub_board_get
  | Board_sub_board_list
  | Context_status
  | Discovery
  | Ide_annotate
  | Stay_silent
  | Tasks_audit
  | Tasks_list
  | Time_now
  | Tools_list
  | Voice_session_end
  | Voice_sessions -> Ungated
;;

let classify_masc_tool (tool : Tool_name.Masc.t) =
  let open Tool_name.Masc in
  match tool with
  | Tool_name.Masc.Code_shell -> Shell
  | Code_git | Worktree_create | Worktree_remove -> Github
  | Code_delete | Code_edit | Code_write -> Filesystem_write
  | Code_read | Code_search | Code_symbols | Worktree_list -> Filesystem_read
  | Web_fetch | Web_search -> Web
  | Board_post
  | Board_comment
  | Board_comment_vote
  | Board_curation_submit
  | Board_delete
  | Board_cleanup
  | Board_reaction
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_update
  | Board_vote -> Board_write
  | Add_task
  | Batch_add_tasks
  | Cancel_task
  | Claim_next
  | Claim_task
  | Complete_task
  | Deliver
  | Dispatch_plan
  | Goal_transition
  | Goal_upsert
  | Goal_verify
  | Heartbeat
  | Join
  | Leave
  | Note_add
  | Operation_pause
  | Operation_start
  | Operation_stop
  | Plan_clear_task
  | Plan_init
  | Plan_set_task
  | Plan_update
  | Register_capabilities
  | Release_task
  | Reset
  | Set_current_task
  | Tool_grant
  | Tool_revoke
  | Transition
  | Update_priority -> Coordination_write
  | Autoresearch_cycle
  | Autoresearch_inject
  | Autoresearch_record_finding
  | Autoresearch_start
  | Autoresearch_stop
  | Agent_update
  | Broadcast
  | Cleanup_zombies
  | Gc
  | Operator_action
  | Operator_confirm
  | Tool_admin_update
  | Webrtc_answer
  | Webrtc_offer -> Generic_write
  | Agent_card
  | Agent_fitness
  | Agents
  | Approval_get
  | Approval_pending
  | Autoresearch_search_findings
  | Autoresearch_status
  | Board_curation_read
  | Board_get
  | Board_hearths
  | Board_list
  | Board_profile
  | Board_search
  | Board_stats
  | Board_sub_board_get
  | Board_sub_board_list
  | Check
  | Config
  | Coord_status
  | Coordination_fsm_snapshot
  | Dashboard
  | Get_metrics
  | Goal_list
  | Goal_review
  | List_tasks
  | Mcp_session
  | Messages
  | Operation_status
  | Operator_digest
  | Operator_snapshot
  | Pause
  | Plan_get
  | Plan_get_task
  | Resume
  | Spawn
  | Start
  | Status
  | Task_history
  | Tasks
  | Tool_admin_snapshot
  | Tool_help
  | Tool_list
  | Tool_stats
  | Who
  | Workflow_guide -> Ungated
;;

let classify_masc_keeper_tool (tool : Tool_name.Masc_keeper.t) =
  let open Tool_name.Masc_keeper in
  match tool with
  | Tool_name.Masc_keeper.Sandbox_start
  | Sandbox_stop
  | Sandbox_status -> Docker
  | Clear | Compact | Create_from_persona | Down | Msg | Repair | Reset | Up ->
    Coordination_write
  | List | Msg_result | Persona_audit | Status -> Ungated
;;

let classify ~tool_name ~arguments ~is_read_only =
  match Tool_name.of_string tool_name with
  | Some (Tool_name.Keeper tool) -> classify_keeper_tool tool arguments
  | Some (Tool_name.Masc tool) -> classify_masc_tool tool
  | Some (Tool_name.Masc_keeper tool) -> classify_masc_keeper_tool tool
  | None ->
    if String.starts_with ~prefix:"keeper_pr_" tool_name then Github
    else if String.equal tool_name "dashboard_worktree_status.gh_pr_list" then Github
    else if String.starts_with ~prefix:"keeper_bash" tool_name then Shell
    else if string_contains tool_name "docker" || string_contains tool_name "sandbox"
    then Docker
    else if string_contains tool_name "web_" then Web
    else if string_contains tool_name "code_" || string_contains tool_name "fs_"
    then if is_read_only then Filesystem_read else Filesystem_write
    else if is_read_only
    then Ungated
    else Generic_write
;;

let gate_timeout_message gate wait_timeout =
  Printf.sprintf
    "Temporary tool resource gate saturated after %.1fs: class=%s limit=%d. \
     This protects active Keeper fleets from host-local tool stampedes; retry \
     after current tool calls drain or raise %s deliberately."
    wait_timeout
    gate.label
    gate.limit
    gate.env_var
;;

let with_permit_raw
      ?wait_timeout_override_sec
      ~clock
      ~tool_name
      ~arguments
      ~is_read_only
      ~on_reject
      f =
  let resource_class = classify ~tool_name ~arguments ~is_read_only in
  if (not (enabled ())) || resource_class = Ungated
  then f ()
  else (
    match gate_for_class resource_class with
    | None -> f ()
    | Some gate ->
      let wait_timeout =
        match wait_timeout_override_sec with
        | Some seconds -> max 0.001 seconds
        | None -> wait_timeout_sec ()
      in
      Atomic.incr gate.waiting;
      let acquired =
        try
          Eio.Time.with_timeout_exn clock wait_timeout (fun () ->
            Eio.Semaphore.acquire gate.semaphore;
            true)
        with
        | Eio.Time.Timeout -> false
        | exn ->
          Atomic.decr gate.waiting;
          raise exn
      in
      Atomic.decr gate.waiting;
      if not acquired
      then (
        Atomic.incr gate.rejected_total;
        let message = gate_timeout_message gate wait_timeout in
        Log.Mcp.warn "tool resource gate rejected: tool=%s %s" tool_name message;
        on_reject message)
      else (
        Atomic.incr gate.acquired_total;
        Eio_guard.protect ~finally:(fun () -> Eio.Semaphore.release gate.semaphore) f))
;;

let with_permit ~clock ~tool_name ~arguments ~is_read_only ~start_time f =
  with_permit_raw
    ~clock
    ~tool_name
    ~arguments
    ~is_read_only
    ~on_reject:(fun message ->
      Tool_result.error
        ~failure_class:(Some Tool_result.Transient_error)
        ~tool_name
        ~start_time
        message)
    f
;;

let gate_json gate =
  let available = Eio.Semaphore.get_value gate.semaphore in
  let active = max 0 (gate.limit - available) in
  `Assoc
    [ "class", `String gate.label
    ; "env_var", `String gate.env_var
    ; "limit", `Int gate.limit
    ; "active", `Int active
    ; "available", `Int available
    ; "waiting", `Int (Atomic.get gate.waiting)
    ; "acquired_total", `Int (Atomic.get gate.acquired_total)
    ; "rejected_total", `Int (Atomic.get gate.rejected_total)
    ]
;;

let snapshot_json () =
  `Assoc
    [ "enabled", `Bool (enabled ())
    ; "wait_timeout_sec", `Float (wait_timeout_sec ())
    ; "gates", `List (List.map gate_json (all_gates ()))
    ]
;;

module For_testing = struct
  let reset () = gates_ref := make_gates ()
  let classify = classify
  let resource_class_to_string = resource_class_to_string

  let set_limits
      ?(shell = 8)
      ?(github = 4)
      ?(docker = 2)
      ?(filesystem_read = 12)
      ?(filesystem_write = 6)
      ?(board_write = 8)
      ?(coordination_write = 12)
      ?(web = 6)
      ?(generic_write = 12)
      () =
    let gate resource_class env_var limit =
      { resource_class
      ; label = label_of_resource_class resource_class
      ; env_var
      ; limit
      ; semaphore = Eio.Semaphore.make limit
      ; waiting = Atomic.make 0
      ; acquired_total = Atomic.make 0
      ; rejected_total = Atomic.make 0
      }
    in
    gates_ref :=
      { shell = gate Shell "MASC_TOOL_GATE_SHELL_MAX" shell
      ; github = gate Github "MASC_TOOL_GATE_GITHUB_MAX" github
      ; docker = gate Docker "MASC_TOOL_GATE_DOCKER_MAX" docker
      ; filesystem_read =
          gate Filesystem_read "MASC_TOOL_GATE_FS_READ_MAX" filesystem_read
      ; filesystem_write =
          gate Filesystem_write "MASC_TOOL_GATE_FS_WRITE_MAX" filesystem_write
      ; board_write = gate Board_write "MASC_TOOL_GATE_BOARD_WRITE_MAX" board_write
      ; coordination_write =
          gate Coordination_write "MASC_TOOL_GATE_COORD_WRITE_MAX" coordination_write
      ; web = gate Web "MASC_TOOL_GATE_WEB_MAX" web
      ; generic_write =
          gate Generic_write "MASC_TOOL_GATE_GENERIC_WRITE_MAX" generic_write
      }
  ;;
end
