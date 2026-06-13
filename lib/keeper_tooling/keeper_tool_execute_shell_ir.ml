module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let classify ir =
  Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
;;

let lit text = Masc_exec.Shell_ir.Lit (text, Masc_exec.Shell_ir.default_meta)

let env_bindings bindings = List.map (fun (key, value) -> key, lit value) bindings

let cwd_scope ?cwd_base raw =
  (* DET-OK: default keeps cwd base equal to the explicit raw cwd; it does not
     infer policy from unknown input. *)
  let cwd = Option.value cwd_base ~default:raw in
  Some (Masc_exec.Path_scope.classify ~raw ~cwd)
;;

let simple_bin
      ?cwd_raw
      ?cwd_base
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?(env = [])
      ?(redirects = [])
      bin
      args
  =
  let cwd =
    match cwd_raw with
    | None -> None
    | Some raw -> cwd_scope ?cwd_base raw
  in
  Masc_exec.Shell_ir.Simple
    { bin
    ; args = List.map lit args
    ; env = env_bindings env
    ; cwd
    ; redirects
    ; sandbox
    }
;;

let simple ?cwd_raw ?cwd_base ?sandbox bin args =
  simple_bin ?cwd_raw ?cwd_base ?sandbox (Masc_exec.Exec_program.of_known bin) args
;;

let pipeline stages = Masc_exec.Shell_ir.Pipeline stages

let with_cwd ~raw ~cwd ir =
  let scope = cwd_scope ~cwd_base:cwd raw in
  let rec map = function
    | Masc_exec.Shell_ir.Simple simple ->
      Masc_exec.Shell_ir.Simple { simple with cwd = scope }
    | Masc_exec.Shell_ir.Pipeline stages ->
      Masc_exec.Shell_ir.Pipeline (List.map map stages)
  in
  map ir
;;

let gate_verdict_map verdict ~f_allow ~f_reject ~f_cannot_parse ~f_too_complex =
  match verdict with
  | Shell_gate.Allow ctx -> f_allow ctx
  | Shell_gate.Reject { diagnostic; _ } -> f_reject diagnostic
  | Shell_gate.Cannot_parse _ -> f_cannot_parse
  | Shell_gate.Too_complex _ -> f_too_complex
;;

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string

let validate_paths ?keeper_id ?base_path ~workdir ir =
  Exec_policy.validate_shell_ir_paths ?keeper_id ?base_path ~workdir ir
;;

let tool_execute_command_context ?(allow_pipes = true) ~allowed_commands command
  =
  match Exec_policy.parse_string_to_ir ~mode:Tool_execute command with
  | Error reason ->
    Error
      (Exec_policy.block_reason_to_string_with_allowlist
         ~allowed_commands
         reason)
  | Ok ir -> (
    match
      Exec_policy.command_context_tool_execute_with_allowlist
        ~allow_pipes
        ~allowed_commands
        ir
    with
    | Ok ctx -> Ok ctx
    | Error reason ->
      Error
        (Exec_policy.block_reason_to_string_with_allowlist
           ~allowed_commands
           reason))
;;

(* TEL-OK: facade is pure gate/path/dispatch routing; the Execute handler emits
   Shell IR dispatch telemetry with keeper, sandbox, status, elapsed_ms. *)
let dispatch_classified
      ?timeout_sec
      ?before_path_validation
      ?(allow_pipes = true)
      ?(redirect_allowed = true)
      ~allowed_commands
      ?keeper_id
      ?base_path
      ~workdir
      ~sandbox
      envelope
  =
  let ir = envelope.Masc_exec.Shell_ir_risk.ir in
  let gate_verdict =
    Shell_gate.gate_typed
      ~ir
      ~allowlist:{ allowed_commands; allow_pipes; redirect_allowed }
      ~path_policy:Shell_gate.forbid_masc_internal_state_paths
      ~sandbox:{ target = sandbox }
      ()
  in
  gate_verdict_map
    gate_verdict
    ~f_reject:(fun diagnostic -> Error (Gate_reject diagnostic))
    ~f_cannot_parse:(Error Cannot_parse)
    ~f_too_complex:(Error Too_complex)
    ~f_allow:(fun _context ->
      match
        match before_path_validation with
        | None -> Ok ()
        | Some validate -> validate ir
      with
      | Error e -> Error (Path_reject e)
      | Ok () ->
        (match validate_paths ?keeper_id ?base_path ~workdir ir with
         | Error e -> Error (Path_reject e)
         | Ok () -> Ok (Masc_exec.Exec_dispatch.dispatch_decided ?timeout_sec envelope)))
;;

(* TEL-OK: wrapper only classifies before delegating to dispatch_classified. *)
let dispatch
      ?timeout_sec
      ?before_path_validation
      ?allow_pipes
      ?redirect_allowed
      ~allowed_commands
      ?keeper_id
      ?base_path
      ~workdir
      ~sandbox
      ir
  =
  dispatch_classified
    ?timeout_sec
    ?before_path_validation
    ?allow_pipes
    ?redirect_allowed
    ~allowed_commands
    ?keeper_id
    ?base_path
    ~workdir
    ~sandbox
    (classify ir)
;;
