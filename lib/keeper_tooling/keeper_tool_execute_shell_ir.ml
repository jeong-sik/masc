module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let lit text = Masc_exec.Shell_ir.Lit (text, Masc_exec.Shell_ir.default_meta)

let env_bindings bindings = List.map (fun (key, value) -> key, lit value) bindings

let cwd_scope ?cwd_base raw =
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

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string

let validate_paths ~workdir ir =
  Exec_policy.validate_shell_ir_paths ~workdir ir
;;

let dispatch
      ?(allow_pipes = true)
      ?(redirect_allowed = true)
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
      ~syntax_policy:{ allow_pipes; redirect_allowed }
      ~sandbox:{ target = sandbox }
      ()
  in
  match gate_verdict with
  | Shell_gate.Reject { diagnostic; _ } -> Error (Gate_reject diagnostic)
  | Shell_gate.Cannot_parse _ -> Error Cannot_parse
  | Shell_gate.Too_complex _ -> Error Too_complex
  | Shell_gate.Allow _context ->
    (match validate_paths ~workdir ir with
     | Error error -> Error (Path_reject error)
     | Ok () ->
       Ok
         (Masc_exec.Exec_dispatch.dispatch
            ?base_host_env
            ?timeout_sec
            ?on_output_chunk
            ir))
;;
