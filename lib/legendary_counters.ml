let gh_exit_ok_0 = Atomic.make 0
let gh_exit_policy_blocked = Atomic.make 0
let gh_exit_type_mismatch = Atomic.make 0
let gh_exit_auth_failed = Atomic.make 0
let gh_exit_network = Atomic.make 0
let gh_exit_unknown = Atomic.make 0

let shell_gate_worker_dev_tools_allow = Atomic.make 0
let shell_gate_worker_dev_tools_reject = Atomic.make 0
let shell_gate_worker_dev_tools_cannot_parse = Atomic.make 0
let shell_gate_tool_code_write_allow = Atomic.make 0
let shell_gate_tool_code_write_reject = Atomic.make 0
let shell_gate_tool_code_write_cannot_parse = Atomic.make 0
let shell_gate_keeper_shell_bash_allow = Atomic.make 0
let shell_gate_keeper_shell_bash_reject = Atomic.make 0
let shell_gate_keeper_shell_bash_cannot_parse = Atomic.make 0

let incr a = ignore (Atomic.fetch_and_add a 1)

let incr_gh_exit_class (c : Gh_exit_class.t) =
  match c with
  | Gh_exit_class.Ok_0 -> incr gh_exit_ok_0
  | Gh_exit_class.Policy_blocked -> incr gh_exit_policy_blocked
  | Gh_exit_class.Type_mismatch -> incr gh_exit_type_mismatch
  | Gh_exit_class.Auth_failed -> incr gh_exit_auth_failed
  | Gh_exit_class.Network -> incr gh_exit_network
  | Gh_exit_class.Unknown -> incr gh_exit_unknown
;;

type shell_gate_caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type shell_gate_verdict_kind =
  | Allow
  | Reject
  | Cannot_parse

let incr_shell_gate ~caller ~verdict =
  let counter =
    match caller, verdict with
    | Worker_dev_tools, Allow -> shell_gate_worker_dev_tools_allow
    | Worker_dev_tools, Reject -> shell_gate_worker_dev_tools_reject
    | Worker_dev_tools, Cannot_parse -> shell_gate_worker_dev_tools_cannot_parse
    | Tool_code_write, Allow -> shell_gate_tool_code_write_allow
    | Tool_code_write, Reject -> shell_gate_tool_code_write_reject
    | Tool_code_write, Cannot_parse -> shell_gate_tool_code_write_cannot_parse
    | Keeper_shell_bash, Allow -> shell_gate_keeper_shell_bash_allow
    | Keeper_shell_bash, Reject -> shell_gate_keeper_shell_bash_reject
    | Keeper_shell_bash, Cannot_parse -> shell_gate_keeper_shell_bash_cannot_parse
  in
  incr counter
;;

let reset () =
  Atomic.set gh_exit_ok_0 0;
  Atomic.set gh_exit_policy_blocked 0;
  Atomic.set gh_exit_type_mismatch 0;
  Atomic.set gh_exit_auth_failed 0;
  Atomic.set gh_exit_network 0;
  Atomic.set gh_exit_unknown 0;
  Atomic.set shell_gate_worker_dev_tools_allow 0;
  Atomic.set shell_gate_worker_dev_tools_reject 0;
  Atomic.set shell_gate_worker_dev_tools_cannot_parse 0;
  Atomic.set shell_gate_tool_code_write_allow 0;
  Atomic.set shell_gate_tool_code_write_reject 0;
  Atomic.set shell_gate_tool_code_write_cannot_parse 0;
  Atomic.set shell_gate_keeper_shell_bash_allow 0;
  Atomic.set shell_gate_keeper_shell_bash_reject 0;
  Atomic.set shell_gate_keeper_shell_bash_cannot_parse 0
;;

type snapshot =
  { gh_exit_ok_0 : int
  ; gh_exit_policy_blocked : int
  ; gh_exit_type_mismatch : int
  ; gh_exit_auth_failed : int
  ; gh_exit_network : int
  ; gh_exit_unknown : int
  ; shell_gate_worker_dev_tools_allow : int
  ; shell_gate_worker_dev_tools_reject : int
  ; shell_gate_worker_dev_tools_cannot_parse : int
  ; shell_gate_tool_code_write_allow : int
  ; shell_gate_tool_code_write_reject : int
  ; shell_gate_tool_code_write_cannot_parse : int
  ; shell_gate_keeper_shell_bash_allow : int
  ; shell_gate_keeper_shell_bash_reject : int
  ; shell_gate_keeper_shell_bash_cannot_parse : int
  }

let snapshot () =
  { gh_exit_ok_0 = Atomic.get gh_exit_ok_0
  ; gh_exit_policy_blocked = Atomic.get gh_exit_policy_blocked
  ; gh_exit_type_mismatch = Atomic.get gh_exit_type_mismatch
  ; gh_exit_auth_failed = Atomic.get gh_exit_auth_failed
  ; gh_exit_network = Atomic.get gh_exit_network
  ; gh_exit_unknown = Atomic.get gh_exit_unknown
  ; shell_gate_worker_dev_tools_allow = Atomic.get shell_gate_worker_dev_tools_allow
  ; shell_gate_worker_dev_tools_reject = Atomic.get shell_gate_worker_dev_tools_reject
  ; shell_gate_worker_dev_tools_cannot_parse =
      Atomic.get shell_gate_worker_dev_tools_cannot_parse
  ; shell_gate_tool_code_write_allow = Atomic.get shell_gate_tool_code_write_allow
  ; shell_gate_tool_code_write_reject = Atomic.get shell_gate_tool_code_write_reject
  ; shell_gate_tool_code_write_cannot_parse =
      Atomic.get shell_gate_tool_code_write_cannot_parse
  ; shell_gate_keeper_shell_bash_allow = Atomic.get shell_gate_keeper_shell_bash_allow
  ; shell_gate_keeper_shell_bash_reject = Atomic.get shell_gate_keeper_shell_bash_reject
  ; shell_gate_keeper_shell_bash_cannot_parse =
      Atomic.get shell_gate_keeper_shell_bash_cannot_parse
  }
;;

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc
    [ "gh_exit_ok_0", `Int s.gh_exit_ok_0
    ; "gh_exit_policy_blocked", `Int s.gh_exit_policy_blocked
    ; "gh_exit_type_mismatch", `Int s.gh_exit_type_mismatch
    ; "gh_exit_auth_failed", `Int s.gh_exit_auth_failed
    ; "gh_exit_network", `Int s.gh_exit_network
    ; "gh_exit_unknown", `Int s.gh_exit_unknown
    ; "shell_gate_worker_dev_tools_allow", `Int s.shell_gate_worker_dev_tools_allow
    ; "shell_gate_worker_dev_tools_reject", `Int s.shell_gate_worker_dev_tools_reject
    ; ( "shell_gate_worker_dev_tools_cannot_parse"
      , `Int s.shell_gate_worker_dev_tools_cannot_parse )
    ; "shell_gate_tool_code_write_allow", `Int s.shell_gate_tool_code_write_allow
    ; "shell_gate_tool_code_write_reject", `Int s.shell_gate_tool_code_write_reject
    ; ( "shell_gate_tool_code_write_cannot_parse"
      , `Int s.shell_gate_tool_code_write_cannot_parse )
    ; "shell_gate_keeper_shell_bash_allow", `Int s.shell_gate_keeper_shell_bash_allow
    ; "shell_gate_keeper_shell_bash_reject", `Int s.shell_gate_keeper_shell_bash_reject
    ; ( "shell_gate_keeper_shell_bash_cannot_parse"
      , `Int s.shell_gate_keeper_shell_bash_cannot_parse )
    ]
;;
