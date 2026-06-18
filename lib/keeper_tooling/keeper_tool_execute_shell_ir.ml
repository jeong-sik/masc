module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let classify ir =
  let checked = Masc_exec.Checked_shell_ir.classify_proof ir in
  Masc_exec.Checked_shell_ir.to_decided_ir checked
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
  | Approval_required of { summary : string; bin : string }
  | Policy_denied of { reason : string }

let validate_paths ?keeper_id ?base_path ~workdir ir =
  (* RFC-0255 section 4.6: path-jail kill-switch. When disabled, skip the
     workspace path whitelist entirely. This also removes the only positional
     write-escape guard on the Host profile ([find_write_escape] covers
     redirect writes only), so it is a short-lived valve, not a steady state.
     removal target: RFC-0255 P5. *)
  if Env_config_runtime.Shell_ir_path_jail.enabled () then
    Exec_policy.validate_shell_ir_paths ?keeper_id ?base_path ~workdir ir
  else Ok ()
;;

let tool_execute_command_context ?(allow_pipes = true) command =
  match Exec_policy.parse_string_to_ir ~mode:Tool_execute command with
  | Error reason -> Error (Exec_policy.block_reason_to_string reason)
  | Ok ir -> (
    match
      Exec_policy.command_context_tool_execute
        ~allow_pipes
        ir
    with
    | Ok ctx -> Ok ctx
    | Error reason -> Error (Exec_policy.block_reason_to_string reason))
;;

(* TEL-OK: facade is pure gate/path/dispatch routing; the Execute handler emits
   Shell IR dispatch telemetry with keeper, sandbox, status, elapsed_ms. *)
let dispatch_classified
      ?(allow_pipes = true)
      ?(redirect_allowed = true)
      ?keeper_id
      ?base_path
      ~workdir
      ~sandbox
      ?base_host_env
      ?on_output_chunk
      envelope
  =
  let ir = envelope.Masc_exec.Shell_ir_risk.ir in
  (* Trust- AND flag-independent catastrophic floor (RFC-0254 §4 lesson (c),
     §5.4).  [dispatch_classified] is the single chokepoint every executed
     command passes through — the [MASC_SHELL_IR_APPROVAL_GATE_ENABLED]=off
     keeper path (keeper_tool_execute_runtime.ml) and the read-ops/evidence
     paths reach it directly — so enforcing the floor here makes it
     unconditional: destructive git, redirect write-escape, and [mkfs] are
     denied even with the approval flag off.  The [_with_approval] wrapper runs
     the same [catastrophic_floor] first via [Approval_policy.decide] (single
     source of truth); on its allow path this re-scan returns [None], so there
     is no double-deny, only one cheap pure scan.  Destructive git has no path
     argument for [validate_paths] to jail, so this floor is its only enforcer
     (RFC-0254 §5.4). *)
  match
    Masc_exec.Approval_policy.catastrophic_floor (Masc_exec.Capability_check.of_ir ir)
  with
  | Some reason ->
    Error (Policy_denied { reason = Masc_exec.Verdict.deny_reason_to_string reason })
  | None ->
    let gate_verdict =
      Shell_gate.gate_typed
        ~ir
        ~syntax_policy:{ allow_pipes; redirect_allowed }
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
        match validate_paths ?keeper_id ?base_path ~workdir ir with
        | Error e -> Error (Path_reject e)
        | Ok () -> Ok (Masc_exec.Exec_dispatch.dispatch_decided ?base_host_env ?on_output_chunk envelope))
;;

(* TEL-OK: wrapper only classifies before delegating to dispatch_classified. *)
let dispatch
      ?allow_pipes
      ?redirect_allowed
      ?keeper_id
      ?base_path
      ~workdir
      ~sandbox
      ?base_host_env
      ?on_output_chunk
      ir
  =
  dispatch_classified
    ?allow_pipes
    ?redirect_allowed
    ?keeper_id
    ?base_path
    ~workdir
    ~sandbox
    ?base_host_env
    ?on_output_chunk
    (classify ir)
;;

(** Extract the last simple stage from an IR for per-command approval policy.
    For a [Simple] IR it is the command itself; for a pipeline it is the
    final stage, whose risk class and binary usually drive the approval
    decision. *)
let last_simple_of_ir ir =
  match ir with
  | Masc_exec.Shell_ir.Simple s -> Some s
  | Masc_exec.Shell_ir.Pipeline stages ->
    (match List.rev stages with
     | Masc_exec.Shell_ir.Simple s :: _ -> Some s
     | _ -> None)
;;

(** Same pipeline as [dispatch_classified], but runs the capability-based
    approval policy gate {i before} the typed gate and path validation
    (the approval decision is made first, then [dispatch_classified] applies
    [Shell_gate.gate_typed] followed by [validate_paths]).
    [Ask] and [Deny] are surfaced as typed errors so the keeper runtime
    can log them and return a structured failure to the model. *)
let dispatch_classified_with_approval
      ?allow_pipes
      ?redirect_allowed
      ?keeper_id
      ?base_path
      ~workdir
      ~sandbox
      ?base_host_env
      ?on_output_chunk
      ~agent_id
      ~approval_config
      envelope
  =
  let ir = envelope.Masc_exec.Shell_ir_risk.ir in
  match last_simple_of_ir ir with
  (* A nested pipeline as the last stage has no representative simple stage
     to classify.  The non-approval [dispatch_classified] path rejects the
     same input via [Shell_gate.gate_typed] as [Too_complex]
     (Unsupported_nested_pipeline), so mirror that here instead of
     mislabeling a parseable command as [Cannot_parse]. *)
  | None -> Error Too_complex
  | Some simple ->
    let caps = Masc_exec.Capability_check.of_ir ir in
    let overlay = Masc_exec.Approval_config.lookup approval_config ~actor:agent_id in
    let raw_source = Format.asprintf "%a" Masc_exec.Shell_ir.pp ir in
    let summary = "shell IR capability approval check" in
    let policy_input = { Masc_exec.Approval_policy.raw_source; summary } in
    (match Masc_exec.Approval_policy.decide policy_input ~overlay ~caps ~simple with
     | Allow _trusted | Suggest_confirm (_trusted, _) ->
       dispatch_classified
         ?allow_pipes
         ?redirect_allowed
         ?keeper_id
         ?base_path
         ~workdir
         ~sandbox
         ?base_host_env
         ?on_output_chunk
         envelope
     | Ask _request ->
       (* The policy wants explicit approval, but the keeper runtime has no
          approval channel yet (RFC v5 HITL path is not wired), so this is a
          block.  Report the binary and risk class so the failure is
          actionable instead of an opaque "approval check" string. *)
       let bin = Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin in
       Error
         (Approval_required
            { summary =
                Printf.sprintf
                  "command '%s' requires approval (audited/privileged risk \
                   class); no approval channel is configured, so it is blocked"
                  bin
            ; bin
            })
     | Deny { reason; caps = _ } ->
       Error
         (Policy_denied { reason = Masc_exec.Verdict.deny_reason_to_string reason }))
;;
