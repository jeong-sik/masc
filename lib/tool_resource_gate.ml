(** Tool_resource_gate — bounded local tool lanes for active Keeper fleets.

    This is intentionally separate from {!Admission_queue}.  OAS/provider
    capacity still belongs to the runtime layer; this module only protects
    host-local MCP tool bottlenecks that a 24-Keeper burst can stampede:
    shell subprocesses, GitHub/gh calls, Docker, filesystem scans,
    board/workspace writes, and web I/O. *)

type resource_class = Tool_resource_axis.t =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
  | Board_write
  | Workspace_write
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
  ; timed_out_total : int Atomic.t
  }

type gates =
  { shell : gate
  ; github : gate
  ; docker : gate
  ; filesystem_read : gate
  ; board_write : gate
  ; workspace_write : gate
  ; web : gate
  ; generic_write : gate
  }

let env_bool ?(default = false) name =
  Safe_ops.get_env_bool_logged name ~default
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

let label_of_resource_class = Tool_resource_axis.to_string

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
  ; timed_out_total = Atomic.make 0
  }
;;

let make_gates () =
  { shell = make_gate Shell "MASC_TOOL_GATE_SHELL_MAX" 8
  ; github = make_gate Github "MASC_TOOL_GATE_GITHUB_MAX" 4
  ; docker = make_gate Docker "MASC_TOOL_GATE_DOCKER_MAX" 2
  ; filesystem_read = make_gate Filesystem_read "MASC_TOOL_GATE_FS_READ_MAX" 12
  ; board_write = make_gate Board_write "MASC_TOOL_GATE_BOARD_WRITE_MAX" 8
  ; workspace_write =
      make_gate Workspace_write "MASC_TOOL_GATE_WORKSPACE_WRITE_MAX" 12
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
  | Board_write -> Some (!gates_ref).board_write
  | Workspace_write -> Some (!gates_ref).workspace_write
  | Web -> Some (!gates_ref).web
  | Generic_write -> Some (!gates_ref).generic_write
;;

let all_gates () =
  let g = !gates_ref in
  [ g.shell
  ; g.github
  ; g.docker
  ; g.filesystem_read
  ; g.board_write
  ; g.workspace_write
  ; g.web
  ; g.generic_write
  ]
;;

let enabled () = not (env_bool "MASC_TOOL_RESOURCE_GATE_DISABLED")
let wait_timeout_sec () = env_float "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" 20.0
let execution_timeout_sec () = env_float "MASC_TOOL_GATE_EXEC_TIMEOUT_SEC" 1800.0

let classify = Tool_resource_axis.classify

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

let gate_execution_timeout_message gate execution_timeout =
  Printf.sprintf
    "Tool resource gate execution lease expired after %.1fs: class=%s limit=%d. \
     The permit was released to prevent one stuck tool call from blocking the \
     Keeper fleet; either fix the stuck tool or raise MASC_TOOL_GATE_EXEC_TIMEOUT_SEC \
     deliberately."
    execution_timeout
    gate.label
    gate.limit
;;

let with_permit_raw
      ?wait_timeout_override_sec
      ?execution_timeout_override_sec
      ~clock
      ~tool_name
      ~arguments
      ~is_read_only
      ~on_reject
      ~on_execution_timeout
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
        let execution_timeout =
          match execution_timeout_override_sec with
          | Some seconds -> max 0.001 seconds
          | None -> execution_timeout_sec ()
        in
        Eio_guard.protect
          ~finally:(fun () -> Eio.Semaphore.release gate.semaphore)
          (fun () ->
             try Eio.Time.with_timeout_exn clock execution_timeout f with
             | Eio.Time.Timeout ->
               Atomic.incr gate.timed_out_total;
               let message = gate_execution_timeout_message gate execution_timeout in
               Log.Mcp.warn
                 "tool resource gate execution timeout: tool=%s %s"
                 tool_name
                 message;
               on_execution_timeout message)))
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
    ~on_execution_timeout:(fun message ->
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
    ; "timed_out_total", `Int (Atomic.get gate.timed_out_total)
    ]
;;

let snapshot_json () =
  `Assoc
    [ "enabled", `Bool (enabled ())
    ; "wait_timeout_sec", `Float (wait_timeout_sec ())
    ; "execution_timeout_sec", `Float (execution_timeout_sec ())
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
      ?(board_write = 8)
      ?(workspace_write = 12)
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
      ; timed_out_total = Atomic.make 0
      }
    in
    gates_ref :=
      { shell = gate Shell "MASC_TOOL_GATE_SHELL_MAX" shell
      ; github = gate Github "MASC_TOOL_GATE_GITHUB_MAX" github
      ; docker = gate Docker "MASC_TOOL_GATE_DOCKER_MAX" docker
      ; filesystem_read =
          gate Filesystem_read "MASC_TOOL_GATE_FS_READ_MAX" filesystem_read
      ; board_write = gate Board_write "MASC_TOOL_GATE_BOARD_WRITE_MAX" board_write
      ; workspace_write =
          gate Workspace_write "MASC_TOOL_GATE_WORKSPACE_WRITE_MAX" workspace_write
      ; web = gate Web "MASC_TOOL_GATE_WEB_MAX" web
      ; generic_write =
          gate Generic_write "MASC_TOOL_GATE_GENERIC_WRITE_MAX" generic_write
      }
  ;;
end
