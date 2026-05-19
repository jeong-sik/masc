let env_var = "MASC_SHELL_GATE_AUTHORITY"

(* Closed-sum tag matcher.  Exhaustive over [Shell_command_gate.caller];
   a new caller variant forces an arm here at compile time.  The
   "all" alias is intentional — it gives a single tag for tests and
   internal benchmarks without enumerating every caller, while
   per-caller tags remain the production interface. *)
let caller_matches tag (c : Shell_command_gate.caller) : bool =
  let normalised = String.lowercase_ascii (String.trim tag) in
  if normalised = "" then false
  else if normalised = "all" then true
  else
    match c with
    | Worker_dev_tools -> normalised = "worker_dev_tools"
    | Tool_code_write -> normalised = "tool_code_write"
    | Keeper_shell_bash -> normalised = "keeper_shell_bash"
;;

let authority_enabled caller =
  match Sys.getenv_opt env_var with
  | None | Some "" -> false
  | Some raw ->
    raw
    |> String.split_on_char ','
    |> List.exists (fun tag -> caller_matches tag caller)
;;
