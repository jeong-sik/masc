(** masc_shell_ir_probe — offline Shell IR boundary probe (read-only).

    Parses a command, applies the structural command boundary, and validates
    explicit cwd/redirect scopes without running it. Authorization belongs to the outer Keeper
    Gate and is deliberately absent from this backend-neutral probe.

    Every layer's outcome is printed independently so a probe shows exactly
    which layer would block a command. Parse failures, gate rejections, and
    exceptions are reported, never raised past the per-command loop — this is
    a stability probe, so a crash on any single command is a finding, not an
    abort.

    Usage:
      masc_shell_ir_probe "ls -la"
      masc_shell_ir_probe --workdir /repo "printf hello | wc -c"
      masc_shell_ir_probe --stdin < commands.txt    (one command per line) *)

module Shell_ir = Masc_exec.Shell_ir
module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let ir_shape = function
  | Shell_ir.Simple _ -> "Simple"
  | Shell_ir.Pipeline stages -> Printf.sprintf "Pipeline(%d stages)" (List.length stages)

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
          ~sandbox:Shell_gate.host_sandbox ()
      with
      | Shell_gate.Allow _ -> Printf.printf "command-gate: ok\n"
      | Shell_gate.Reject { diagnostic; _ } ->
        Printf.printf "command-gate: BLOCKED — %s\n" diagnostic
      | Shell_gate.Cannot_parse _ ->
        Printf.printf "command-gate: BLOCKED — cannot parse (chain/redirect/injection)\n"
      | Shell_gate.Too_complex _ ->
        Printf.printf "command-gate: BLOCKED — unsupported construct (too complex)\n");
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
  Printf.printf "# masc_shell_ir_probe  workdir=%s mode=Tool_execute\n\n" !workdir;
  List.iter (fun c -> if String.trim c <> "" then probe_safe ~workdir:!workdir c) commands
