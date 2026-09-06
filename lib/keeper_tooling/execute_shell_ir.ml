module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let lit text = Masc_exec.Shell_ir.Lit (text, Masc_exec.Shell_ir.default_meta)

let cwd_scope ?cwd_base raw =
  let cwd = Option.value cwd_base ~default:raw in
  Some (Masc_exec.Path_scope.classify ~raw ~cwd)
;;

let simple_bin
      ?cwd_raw
      ?cwd_base
      ?(sandbox = Masc_exec.Sandbox_target.host ())
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
    ; env = []
    ; cwd
    ; redirects = []
    ; sandbox
    }
;;

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse of Shell_gate.parse_reason
  | Too_complex of Shell_gate.too_complex_reason
  | Path_reject of string

let parse_reason_tag = Shell_gate.parse_reason_tag
let too_complex_reason_tag = Shell_gate.too_complex_reason_tag

let requires_existing_dir_of_sandbox = function
  | Masc_exec.Sandbox_target.Host
  | Docker _ -> true
  | Micro_vm _ | Ssh _ | Delegated _ -> false
;;

let validate_paths ?requires_existing_dir ?sandbox ~workdir ir =
  let requires_existing_dir =
    match requires_existing_dir, sandbox with
    | Some req, _ -> req
    | None, Some target -> requires_existing_dir_of_sandbox target
    | None, None -> true
  in
  Exec_policy.validate_shell_ir_paths ~requires_existing_dir ~workdir ir
;;

let dispatch
      ?(allow_pipes = true)
      ~workdir
      ~sandbox
      ?base_host_env
      ?timeout_sec
      ?on_output_chunk
      ir
  =
  let gate_verdict =
    Shell_gate.gate_typed
      ~ir
      ~syntax_policy:{ allow_pipes; redirect_allowed = true }
      ~sandbox:{ target = sandbox }
      ()
  in
  match gate_verdict with
  | Shell_gate.Reject { diagnostic; _ } -> Error (Gate_reject diagnostic)
  | Shell_gate.Cannot_parse { reason } -> Error (Cannot_parse reason)
  | Shell_gate.Too_complex { reason } -> Error (Too_complex reason)
  | Shell_gate.Allow _context ->
    (match validate_paths ~sandbox ~workdir ir with
     | Error error -> Error (Path_reject error)
     | Ok () ->
       Ok
         (Masc_exec.Exec_dispatch.dispatch
            ?base_host_env
            ?timeout_sec
            ?on_output_chunk
            ir))
;;
