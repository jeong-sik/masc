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

type approval_required_kind =
  | Gh_capability_requires_approval
  | Privileged_program_floor

let approval_required_kind_to_string = function
  | Gh_capability_requires_approval -> "gh_capability_requires_approval"
  | Privileged_program_floor -> "privileged_program_floor"
;;

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string
  | Approval_required of {
      summary : string;
      bin : string;
      kind : approval_required_kind;
    }
  | Policy_denied of { reason : string }

let rec first_privileged_program = function
  | [] -> None
  | cap :: rest ->
    let found =
      match cap with
      | Masc_exec.Capability.Exec_program (bin, _)
        when Masc_exec.Exec_program.risk_class bin = `Privileged -> Some bin
      | Masc_exec.Capability.Exec_program _ -> None
      | Masc_exec.Capability.Read_path _ -> None
      | Masc_exec.Capability.Write_path _ -> None
      | Masc_exec.Capability.Git _ -> None
      | Masc_exec.Capability.Env_set _ -> None
      | Masc_exec.Capability.Pipeline_fold inner -> first_privileged_program inner
    in
    (match found with
     | Some _ -> found
     | None -> first_privileged_program rest)
;;

(* Public seam shared by direct Shell IR dispatch and Docker sandbox host-path
   validation, where container paths are first rewritten for the host policy
   check.  Keeping the facade here ensures both routes use the same jail. *)
let validate_paths ?keeper_id ?base_path ~workdir ir =
  Exec_policy.validate_shell_ir_paths ?keeper_id ?base_path ~workdir ir
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
let last_simple_of_ir ir =
  match ir with
  | Masc_exec.Shell_ir.Simple s -> Some s
  | Masc_exec.Shell_ir.Pipeline stages ->
    (match List.rev stages with
     | Masc_exec.Shell_ir.Simple s :: _ -> Some s
     | _ -> None)
;;

type gh_capability_policy_result =
  | Gh_policy_noop
  | Gh_policy_approval_required of Masc_exec.Exec_program.t
  | Gh_policy_denied of string

(* Surface WHY a gh command is gated on the operator approval prompt: the gh
   family/action and its verb classification (read / reversible / irreversible
   mutation / …). Returns [None] when the command's words are not literally
   recoverable (env/redirect/$VAR present) so no rationale is fabricated. *)
let gh_gating_detail ir =
  match last_simple_of_ir ir with
  | None -> None
  | Some simple ->
    (match Masc_exec.Shell_ir_risk.literal_words_of_simple simple with
     | None -> None
     | Some words ->
       let verb = Masc_exec.Gh_verb.classify words in
       let verb_class = Masc_exec.Shell_ir_risk.classify_gh_verb verb in
       let family = Masc_exec.Gh_verb.string_of_family verb.Masc_exec.Gh_verb.family in
       let action = Option.value ~default:"" verb.Masc_exec.Gh_verb.action in
       let subject = String.trim (family ^ " " ^ action) in
       let subject = if subject = "" then "gh" else "gh " ^ subject in
       Some
         (Printf.sprintf
            "%s: %s"
            subject
            (Masc_exec.Shell_ir_risk.gh_verb_class_to_string verb_class)))
;;

let gh_capability_policy_result ir ~caps =
  match last_simple_of_ir ir with
  | None -> Gh_policy_noop
  | Some simple ->
    let raw_source = Format.asprintf "%a" Masc_exec.Shell_ir.pp ir in
    let summary = "shell IR capability approval check" in
    let policy_input = { Masc_exec.Approval_policy.raw_source; summary } in
    (match
       Masc_exec.Approval_policy.decide
         policy_input
         ~overlay:Masc_exec.Approval_config.autonomous
         ~caps
         ~simple
     with
     | Masc_exec.Verdict.Ask { bin; _ } ->
       (match Masc_exec.Exec_program.known bin with
        | Some Masc_exec.Exec_program.Gh -> Gh_policy_approval_required bin
        | Some _ | None -> Gh_policy_noop)
     | Masc_exec.Verdict.Allow _ | Masc_exec.Verdict.Suggest_confirm (_, _) ->
       Gh_policy_noop
     | Masc_exec.Verdict.Deny { reason; _ } ->
       Gh_policy_denied (Masc_exec.Verdict.deny_reason_to_string reason))
;;

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
  let caps = Masc_exec.Capability_check.of_ir ir in
  (* Trust- and flag-independent safety floors.  [dispatch_classified] is the
     single chokepoint every executed command passes through, including the
     [MASC_SHELL_IR_APPROVAL_GATE_ENABLED]=off route.  The catastrophic floor is
     never approvable; the privileged-program floor is fail-closed until a real
     Shell IR approval resolver is wired.  [Exec_program.risk_class] is derived
     from the closed [Exec_program.known] metadata registry, and unknown
     binaries are classified as [`Privileged] in [Exec_program.of_string].  The
     capability scan above enumerates every [Capability.t] arm so new
     execution-bearing capabilities cannot silently bypass this floor. *)
  match Masc_exec.Approval_policy.catastrophic_floor caps with
  | Some reason ->
    Error (Policy_denied { reason = Masc_exec.Verdict.deny_reason_to_string reason })
  | None ->
    (match gh_capability_policy_result ir ~caps with
     | Gh_policy_denied reason -> Error (Policy_denied { reason })
     | Gh_policy_approval_required bin ->
       let bin = Masc_exec.Exec_program.to_string bin in
       let summary =
         match gh_gating_detail ir with
         | Some detail ->
           Printf.sprintf
             "command '%s' requires approval — %s (audited/privileged risk class)"
             bin
             detail
         | None ->
           Printf.sprintf
             "command '%s' requires approval (audited/privileged risk class)"
             bin
       in
       Error
         (Approval_required
            { summary; bin; kind = Gh_capability_requires_approval })
     | Gh_policy_noop ->
       (match first_privileged_program caps with
        | Some bin ->
          let bin = Masc_exec.Exec_program.to_string bin in
          Error
            (Approval_required
               { summary =
                   Printf.sprintf
                     "privileged command '%s' requires explicit approval; no \
                      Shell IR approval resolver is configured, so it is blocked"
                     bin
               ; bin
               ; kind = Privileged_program_floor
               })
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
              | Ok () ->
                Ok
                  (Masc_exec.Exec_dispatch.dispatch_decided
                     ?base_host_env
                     ?on_output_chunk
                     envelope))))
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

(** Same pipeline as [dispatch_classified], but runs the capability-based
    approval policy gate {i before} the typed gate and path validation
    (the approval decision is made first, then [dispatch_classified] applies
    [Shell_gate.gate_typed] followed by [validate_paths]).
    [Ask] and [Deny] are surfaced as typed errors so the keeper runtime
    can log them and either enqueue non-blocking HITL for gh capabilities or
    return a structured failure to the model.  Even when the policy overlay
    allows, [dispatch_classified] still applies the privileged fail-closed
    floor before dispatch. *)
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
     | Ask { bin = request_bin; _ } ->
       let kind =
         match Masc_exec.Exec_program.known request_bin with
         | Some Masc_exec.Exec_program.Gh -> Gh_capability_requires_approval
         | Some _ | None -> Privileged_program_floor
       in
       let bin = Masc_exec.Exec_program.to_string request_bin in
       Error
         (Approval_required
            { summary =
                Printf.sprintf
                  "command '%s' requires approval (audited/privileged risk \
                   class)"
                  bin
            ; bin
            ; kind
            })
     | Deny { reason; caps = _ } ->
       Error
         (Policy_denied { reason = Masc_exec.Verdict.deny_reason_to_string reason }))
;;
