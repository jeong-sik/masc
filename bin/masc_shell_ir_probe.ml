(** masc_shell_ir_probe — offline Shell IR pipeline probe (read-only).

    Feeds a shell command string through the same decision layers the keeper
    Execute path uses, WITHOUT running it:

      1. Exec_policy.parse_string_to_ir ~mode:Tool_execute      (parse)
      2. Shell_command_gate.gate_typed                          (command gate)
      3. Capability_check.of_ir                                 (capabilities)
      4. Approval_policy.decide ~overlay:autonomous             (four-way verdict)
      5. Exec_policy.validate_shell_ir_paths ~workdir           (downstream path jail)

    Layers 2 and 5 mirror keeper_tool_execute_shell_ir.dispatch_classified,
    which calls Shell_command_gate.gate_typed then validate_shell_ir_paths.
    Layer 2 deliberately does NOT use Exec_policy.validate_command_tool_execute:
    that wraps gate_typed with an extra validate_no_unquoted_glob check no live
    keeper path applies, so it over-reports blocks on unquoted-glob commands
    (e.g. [gh api /r/check-runs?sha=x], [ls *.ml]) keepers actually run.
    (baseline.jsonl pins this: [ls *.txt] -> ir_verdict=allow, worker=injection.)

    Every layer's outcome is printed independently so a probe shows exactly
    which layer would block a command. Parse failures, gate rejections, and
    exceptions are reported, never raised past the per-command loop — this is
    a stability probe, so a crash on any single command is a finding, not an
    abort.

    Usage:
      masc_shell_ir_probe "gh api /repos/jeong-sik/masc/check-runs"
      masc_shell_ir_probe --workdir /repo "rm -rf /" "git reset --hard"
      masc_shell_ir_probe --stdin < commands.txt    (one command per line) *)

module Shell_ir = Masc_exec.Shell_ir
module Exec_program = Masc_exec.Exec_program
module Capability = Masc_exec.Capability
module Capability_check = Masc_exec.Capability_check
module Approval_policy = Masc_exec.Approval_policy
module Approval_config = Masc_exec.Approval_config
module Verdict = Masc_exec.Verdict
module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let probe_policy : Approval_policy.t = { raw_source = "(probe)"; summary = "(probe)" }

let last_simple_of_ir = function
  | Shell_ir.Simple s -> Some s
  | Shell_ir.Pipeline stages -> (
    match List.rev stages with Shell_ir.Simple s :: _ -> Some s | _ -> None)

let ir_shape = function
  | Shell_ir.Simple _ -> "Simple"
  | Shell_ir.Pipeline stages -> Printf.sprintf "Pipeline(%d stages)" (List.length stages)

let render_caps = function
  | [] -> "(none)"
  | caps ->
    caps
    |> List.map (fun c -> Format.asprintf "%a" Capability.pp c)
    |> String.concat "; "

let render_verdict = function
  | Verdict.Allow t ->
    Printf.sprintf "Allow (bin=%s)" (Exec_program.to_string (Verdict.Trusted_argv.bin t))
  | Verdict.Suggest_confirm (t, _) ->
    Printf.sprintf "Suggest_confirm (bin=%s)"
      (Exec_program.to_string (Verdict.Trusted_argv.bin t))
  | Verdict.Ask req ->
    Printf.sprintf "Ask (bin=%s) — %s" (Exec_program.to_string req.Verdict.bin)
      req.Verdict.summary
  | Verdict.Deny { reason; _ } -> Printf.sprintf "Deny — %s" (Verdict.deny_reason_to_string reason)

let probe ~workdir command =
  Printf.printf "cmd:          %s\n" command;
  (match Exec_policy.parse_string_to_ir ~mode:Tool_execute command with
   | Error reason ->
     Printf.printf "parse:        BLOCKED — %s\n" (Exec_policy.block_reason_to_string reason)
   | Ok ir ->
     Printf.printf "parse:        ok (%s)\n" (ir_shape ir);
     (match
        Shell_gate.gate_typed ~ir
          ~syntax_policy:{ Shell_gate.redirect_allowed = true; allow_pipes = true }
          ~path_policy:Shell_gate.allow_all_paths ~sandbox:Shell_gate.host_sandbox ()
      with
      | Shell_gate.Allow _ -> Printf.printf "command-gate: ok\n"
      | Shell_gate.Reject { diagnostic; _ } ->
        Printf.printf "command-gate: BLOCKED — %s\n" diagnostic
      | Shell_gate.Cannot_parse _ ->
        Printf.printf "command-gate: BLOCKED — cannot parse (chain/redirect/injection)\n"
      | Shell_gate.Too_complex _ ->
        Printf.printf "command-gate: BLOCKED — unsupported construct (too complex)\n");
     Printf.printf "caps:         %s\n" (render_caps (Capability_check.of_ir ir));
     (match last_simple_of_ir ir with
      | None -> Printf.printf "verdict:      (no simple stage)\n"
      | Some simple ->
        let caps = Capability_check.of_simple simple in
        let verdict =
          Approval_policy.decide probe_policy ~overlay:Approval_config.autonomous ~caps ~simple
        in
        Printf.printf "verdict:      %s\n" (render_verdict verdict));
     match Exec_policy.validate_shell_ir_paths ~workdir ir with
     | Ok () -> Printf.printf "path-jail:    OK\n"
     | Error e -> Printf.printf "path-jail:    BLOCKED — %s\n" e);
  print_newline ()

let probe_safe ~workdir command =
  try probe ~workdir command
  with exn ->
    Printf.printf "cmd:          %s\nEXCEPTION:    %s\n\n" command (Printexc.to_string exn)

let () =
  let workdir = ref "/tmp" in
  let from_stdin = ref false in
  let commands = ref [] in
  let rec parse = function
    | [] -> ()
    | "--workdir" :: dir :: rest ->
      workdir := dir;
      parse rest
    | "--stdin" :: rest ->
      from_stdin := true;
      parse rest
    | c :: rest ->
      commands := c :: !commands;
      parse rest
  in
  parse (List.tl (Array.to_list Sys.argv));
  let commands =
    if !from_stdin then (
      let acc = ref [] in
      (try
         while true do
           acc := input_line stdin :: !acc
         done
       with End_of_file -> ());
      List.rev !acc)
    else List.rev !commands
  in
  Printf.printf "# masc_shell_ir_probe  workdir=%s overlay=autonomous mode=Tool_execute\n\n"
    !workdir;
  List.iter (fun c -> if String.trim c <> "" then probe_safe ~workdir:!workdir c) commands
