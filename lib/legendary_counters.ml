let auto_bg_observed = Atomic.make 0
let auto_bg_would_have_promoted = Atomic.make 0

let gh_exit_ok_0 = Atomic.make 0
let gh_exit_policy_blocked = Atomic.make 0
let gh_exit_type_mismatch = Atomic.make 0
let gh_exit_auth_failed = Atomic.make 0
let gh_exit_network = Atomic.make 0
let gh_exit_unknown = Atomic.make 0

(* RFC-0092 Phase A typed-advisor parity counters. Increment only
   while [Gate_diff_types.typed_advisor_log_enabled ()] is true.
   Three buckets mirror the [Shell_ir_validator.advisory] sum
   exhaustively so a future variant is a compile error in
   [incr_typed_advisor]. *)
let typed_advisor_allow = Atomic.make 0
let typed_advisor_reject = Atomic.make 0
let typed_advisor_cannot_parse = Atomic.make 0

(* RFC-0131 PR-3 — caller × verdict partition for the
   [Shell_command_gate] facade. 3 callers × 3 verdicts = 9 atomic
   counters. Names follow [shell_gate_<caller>_<verdict>]; the
   typed-dispatch in [incr_shell_gate] is exhaustive over both sums
   so a new caller or verdict variant is a compile error. *)
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

let incr_auto_bg_observed ~promoted_candidate =
  incr auto_bg_observed;
  if promoted_candidate then incr auto_bg_would_have_promoted

let incr_gh_exit_class (c : Gh_exit_class.t) =
  match c with
  | Gh_exit_class.Ok_0 -> incr gh_exit_ok_0
  | Gh_exit_class.Policy_blocked -> incr gh_exit_policy_blocked
  | Gh_exit_class.Type_mismatch -> incr gh_exit_type_mismatch
  | Gh_exit_class.Auth_failed -> incr gh_exit_auth_failed
  | Gh_exit_class.Network -> incr gh_exit_network
  | Gh_exit_class.Unknown -> incr gh_exit_unknown

(* RFC-0092 Phase A typed-advisor parity dispatch. Exhaustive over
   [Shell_ir_validator.advisory]; a new variant in the validator
   forces an update here at compile time. *)
let incr_typed_advisor (a : Shell_ir_validator.advisory) =
  match a with
  | Shell_ir_validator.Allow -> incr typed_advisor_allow
  | Shell_ir_validator.Reject _ -> incr typed_advisor_reject
  | Shell_ir_validator.Cannot_parse _ -> incr typed_advisor_cannot_parse

(* RFC-0131 PR-3 — typed dispatch for caller × verdict partition.
   Exhaustive over [shell_gate_caller × shell_gate_verdict_kind]; a
   new variant in either sum forces an update here at compile time. *)
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

let reset () =
  Atomic.set auto_bg_observed 0;
  Atomic.set auto_bg_would_have_promoted 0;
  Atomic.set gh_exit_ok_0 0;
  Atomic.set gh_exit_policy_blocked 0;
  Atomic.set gh_exit_type_mismatch 0;
  Atomic.set gh_exit_auth_failed 0;
  Atomic.set gh_exit_network 0;
  Atomic.set gh_exit_unknown 0;
  Atomic.set typed_advisor_allow 0;
  Atomic.set typed_advisor_reject 0;
  Atomic.set typed_advisor_cannot_parse 0;
  Atomic.set shell_gate_worker_dev_tools_allow 0;
  Atomic.set shell_gate_worker_dev_tools_reject 0;
  Atomic.set shell_gate_worker_dev_tools_cannot_parse 0;
  Atomic.set shell_gate_tool_code_write_allow 0;
  Atomic.set shell_gate_tool_code_write_reject 0;
  Atomic.set shell_gate_tool_code_write_cannot_parse 0;
  Atomic.set shell_gate_keeper_shell_bash_allow 0;
  Atomic.set shell_gate_keeper_shell_bash_reject 0;
  Atomic.set shell_gate_keeper_shell_bash_cannot_parse 0

type snapshot = {
  auto_bg_observed : int;
  auto_bg_would_have_promoted : int;
  gh_exit_ok_0 : int;
  gh_exit_policy_blocked : int;
  gh_exit_type_mismatch : int;
  gh_exit_auth_failed : int;
  gh_exit_network : int;
  gh_exit_unknown : int;
  (* RFC-0092 Phase A typed-advisor parity counters. Increment only
     while [Gate_diff_types.typed_advisor_log_enabled ()] is true. *)
  typed_advisor_allow : int;
  typed_advisor_reject : int;
  typed_advisor_cannot_parse : int;
  (* RFC-0131 PR-3: exec shell gate caller/verdict partition. *)
  shell_gate_worker_dev_tools_allow : int;
  shell_gate_worker_dev_tools_reject : int;
  shell_gate_worker_dev_tools_cannot_parse : int;
  shell_gate_tool_code_write_allow : int;
  shell_gate_tool_code_write_reject : int;
  shell_gate_tool_code_write_cannot_parse : int;
  shell_gate_keeper_shell_bash_allow : int;
  shell_gate_keeper_shell_bash_reject : int;
  shell_gate_keeper_shell_bash_cannot_parse : int;
}

let snapshot () =
  {
    auto_bg_observed = Atomic.get auto_bg_observed;
    auto_bg_would_have_promoted = Atomic.get auto_bg_would_have_promoted;
    gh_exit_ok_0 = Atomic.get gh_exit_ok_0;
    gh_exit_policy_blocked = Atomic.get gh_exit_policy_blocked;
    gh_exit_type_mismatch = Atomic.get gh_exit_type_mismatch;
    gh_exit_auth_failed = Atomic.get gh_exit_auth_failed;
    gh_exit_network = Atomic.get gh_exit_network;
    gh_exit_unknown = Atomic.get gh_exit_unknown;
    typed_advisor_allow = Atomic.get typed_advisor_allow;
    typed_advisor_reject = Atomic.get typed_advisor_reject;
    typed_advisor_cannot_parse = Atomic.get typed_advisor_cannot_parse;
    shell_gate_worker_dev_tools_allow =
      Atomic.get shell_gate_worker_dev_tools_allow;
    shell_gate_worker_dev_tools_reject =
      Atomic.get shell_gate_worker_dev_tools_reject;
    shell_gate_worker_dev_tools_cannot_parse =
      Atomic.get shell_gate_worker_dev_tools_cannot_parse;
    shell_gate_tool_code_write_allow =
      Atomic.get shell_gate_tool_code_write_allow;
    shell_gate_tool_code_write_reject =
      Atomic.get shell_gate_tool_code_write_reject;
    shell_gate_tool_code_write_cannot_parse =
      Atomic.get shell_gate_tool_code_write_cannot_parse;
    shell_gate_keeper_shell_bash_allow =
      Atomic.get shell_gate_keeper_shell_bash_allow;
    shell_gate_keeper_shell_bash_reject =
      Atomic.get shell_gate_keeper_shell_bash_reject;
    shell_gate_keeper_shell_bash_cannot_parse =
      Atomic.get shell_gate_keeper_shell_bash_cannot_parse;
  }

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    ("auto_bg_observed", `Int s.auto_bg_observed);
    ("auto_bg_would_have_promoted", `Int s.auto_bg_would_have_promoted);
    ("gh_exit_ok_0", `Int s.gh_exit_ok_0);
    ("gh_exit_policy_blocked", `Int s.gh_exit_policy_blocked);
    ("gh_exit_type_mismatch", `Int s.gh_exit_type_mismatch);
    ("gh_exit_auth_failed", `Int s.gh_exit_auth_failed);
    ("gh_exit_network", `Int s.gh_exit_network);
    ("gh_exit_unknown", `Int s.gh_exit_unknown);
    ("typed_advisor_allow", `Int s.typed_advisor_allow);
    ("typed_advisor_reject", `Int s.typed_advisor_reject);
    ("typed_advisor_cannot_parse", `Int s.typed_advisor_cannot_parse);
    ("shell_gate_worker_dev_tools_allow",
     `Int s.shell_gate_worker_dev_tools_allow);
    ("shell_gate_worker_dev_tools_reject",
     `Int s.shell_gate_worker_dev_tools_reject);
    ("shell_gate_worker_dev_tools_cannot_parse",
     `Int s.shell_gate_worker_dev_tools_cannot_parse);
    ("shell_gate_tool_code_write_allow",
     `Int s.shell_gate_tool_code_write_allow);
    ("shell_gate_tool_code_write_reject",
     `Int s.shell_gate_tool_code_write_reject);
    ("shell_gate_tool_code_write_cannot_parse",
     `Int s.shell_gate_tool_code_write_cannot_parse);
    ("shell_gate_keeper_shell_bash_allow",
     `Int s.shell_gate_keeper_shell_bash_allow);
    ("shell_gate_keeper_shell_bash_reject",
     `Int s.shell_gate_keeper_shell_bash_reject);
    ("shell_gate_keeper_shell_bash_cannot_parse",
     `Int s.shell_gate_keeper_shell_bash_cannot_parse);
  ]

let safe_ratio ~num ~den =
  if den <= 0 then 0.0 else float_of_int num /. float_of_int den

let auto_bg_promotion_rate (s : snapshot) : float =
  safe_ratio
    ~num:s.auto_bg_would_have_promoted
    ~den:s.auto_bg_observed

let snapshot_to_json_with_ratios (s : snapshot) : Yojson.Safe.t =
  match snapshot_to_json s with
  | `Assoc fields ->
      `Assoc (fields @ [
        ("ratios",
         `Assoc [
           ("auto_bg_promotion_rate", `Float (auto_bg_promotion_rate s));
         ]);
      ])
  | other -> other
