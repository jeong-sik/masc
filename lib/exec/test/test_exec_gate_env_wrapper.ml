(* RFC-0208 env allowlist-bypass regression guard.

   `env` is on the dev/readonly command allowlists so a keeper can set an
   environment variable for an allowed command (`env FOO=bar npm test`).
   Before the gate resolved the effective command, `env` was a hole: the
   gate saw bin=`env` (allowlisted) and never looked at the wrapped
   command, so `env rm -rf /` ran on even the readonly keeper.

   These assertions pin the fix at the single authorization chokepoint
   ([Shell_command_gate.gate_typed]), covering both the string-parsed path
   and the typed-input path (the IR is built directly, without Bash) — the
   latter is exactly what a parser-only fix would have missed. *)
open Masc_exec
module Gate = Masc_exec_command_gate.Shell_command_gate

let dev = [ "env"; "cat"; "ls"; "npm" ]
let readonly = [ "env"; "cat"; "ls" ]

let policy allowed =
  { Gate.redirect_allowed = true; allowed_commands = allowed; allow_pipes = true }
;;

let sandbox = { Gate.target = Sandbox_target.host () }

let gate ~allowed ir =
  Gate.gate_typed
    ~caller:Gate.Agent_tool_execute_shell_ir
    ~ir
    ~allowlist:(policy allowed)
    ~path_policy:Gate.allow_all_paths
    ~sandbox
    ()
;;

let is_allow = function
  | Gate.Allow _ -> true
  | _ -> false
;;

let is_reject = function
  | Gate.Reject _ -> true
  | _ -> false
;;

let is_wrapper_unreducible = function
  | Gate.Reject { reason = Gate.Wrapper_unreducible _; _ } -> true
  | _ -> false
;;

let parse cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | _ -> failwith (Printf.sprintf "parse failed: %s" cmd)
;;

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

let typed_simple bin args =
  Shell_ir.Simple
    { Shell_ir.bin = Result.get_ok (Exec_program.of_string bin)
    ; args = List.map lit args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
;;

let check name cond = if not cond then failwith ("FAIL: " ^ name)

let test_env_bypass_closed () =
  (* The hole: env smuggling a non-allowlisted command — now rejected. *)
  check "env rm -rf / rejected" (is_reject (gate ~allowed:readonly (parse "env rm -rf /")));
  check
    "env FOO=bar rm -rf / rejected"
    (is_reject (gate ~allowed:readonly (parse "env FOO=bar rm -rf /")));
  check
    "env env rm -rf / (nested) rejected"
    (is_reject (gate ~allowed:readonly (parse "env env rm -rf /")));
  (* Per-stage: a pipeline stage hidden behind env is still caught. *)
  check
    "cat x | env rm -rf / rejected"
    (is_reject (gate ~allowed:readonly (parse "cat x | env rm -rf /")))
;;

let test_uncertain_denies () =
  (* env -S runs its string arg as a command we cannot statically reduce:
     secure default is deny, never silently allow `env`. *)
  check
    "env -S 'rm -rf /' wrapper_unreducible"
    (is_wrapper_unreducible (gate ~allowed:readonly (parse "env -S 'rm -rf /'")))
;;

let test_legit_env_preserved () =
  (* env's own flags are skipped; the inner command is authorized. *)
  check "env -i cat x allowed" (is_allow (gate ~allowed:readonly (parse "env -i cat x")));
  check
    "env -u PATH cat x allowed (value flag skipped, cat is the command)"
    (is_allow (gate ~allowed:readonly (parse "env -u PATH cat x")));
  check "bare env allowed (read)" (is_allow (gate ~allowed:readonly (parse "env")));
  (* Legit var-setting for an allowed command keeps working. *)
  check
    "env FOO=bar npm test allowed (dev)"
    (is_allow (gate ~allowed:dev (parse "env FOO=bar npm test")));
  check "env npm install allowed (dev)" (is_allow (gate ~allowed:dev (parse "env npm install")));
  (* Non-env commands are unaffected. *)
  check "cat x allowed (baseline)" (is_allow (gate ~allowed:readonly (parse "cat x")))
;;

let test_typed_input_path () =
  (* The IR built directly from {bin; args} — no Bash parse. A parser-only
     fix would miss this; the gate-layer fix must cover it. *)
  check
    "{bin=env,args=[rm,-rf,/]} rejected"
    (is_reject (gate ~allowed:readonly (typed_simple "env" [ "rm"; "-rf"; "/" ])));
  check
    "{bin=env,args=[cat,x]} allowed"
    (is_allow (gate ~allowed:readonly (typed_simple "env" [ "cat"; "x" ])))
;;

let () =
  test_env_bypass_closed ();
  test_uncertain_denies ();
  test_legit_env_preserved ();
  test_typed_input_path ();
  print_endline "[test_exec_gate_env_wrapper] all tests passed"
;;
