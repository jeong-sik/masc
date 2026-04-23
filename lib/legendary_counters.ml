let gate_diff_total = Atomic.make 0
let gate_diff_agree = Atomic.make 0
let gate_diff_legacy_allow_shadow_deny = Atomic.make 0
let gate_diff_legacy_deny_shadow_allow = Atomic.make 0
let gate_diff_shadow_cannot_parse = Atomic.make 0
let auto_bg_observed = Atomic.make 0
let auto_bg_would_have_promoted = Atomic.make 0

let too_complex_redirect = Atomic.make 0
let too_complex_logic_op = Atomic.make 0
let too_complex_heredoc = Atomic.make 0
let too_complex_here_string = Atomic.make 0
let too_complex_cmd_subst = Atomic.make 0
let too_complex_proc_subst = Atomic.make 0
let too_complex_subshell = Atomic.make 0
let too_complex_arith_expansion = Atomic.make 0
let too_complex_control_flow = Atomic.make 0
let too_complex_function_def = Atomic.make 0
let too_complex_glob_brace = Atomic.make 0
let too_complex_background = Atomic.make 0
let too_complex_parse_error = Atomic.make 0
let too_complex_parse_aborted = Atomic.make 0
let too_complex_other = Atomic.make 0

let incr a = ignore (Atomic.fetch_and_add a 1)

let incr_gate_diff (diff : Gate_diff_types.gate_diff) =
  incr gate_diff_total;
  match diff with
  | Agree -> incr gate_diff_agree
  | Legacy_allow_shadow_deny -> incr gate_diff_legacy_allow_shadow_deny
  | Legacy_deny_shadow_allow -> incr gate_diff_legacy_deny_shadow_allow
  | Shadow_cannot_parse -> incr gate_diff_shadow_cannot_parse

let incr_auto_bg_observed ~promoted_candidate =
  incr auto_bg_observed;
  if promoted_candidate then incr auto_bg_would_have_promoted

(* Strip the [too_complex:] / [parse_aborted:] prefix if present, so
   callers can pass either the full [shadow_parse_outcome] tag or a
   bare reason name. *)
let bare_reason s =
  let strip prefix =
    let n = String.length prefix in
    if String.length s >= n && String.sub s 0 n = prefix
    then String.sub s n (String.length s - n)
    else s
  in
  strip "too_complex:" |> fun s ->
  if Base.String.is_prefix s ~prefix:"parse_aborted:"
  then "__parse_aborted__"
  else s

let incr_too_complex_by_tag tag =
  match bare_reason tag with
  | "redirect" -> incr too_complex_redirect
  | "logic_op" -> incr too_complex_logic_op
  | "heredoc" -> incr too_complex_heredoc
  | "here_string" -> incr too_complex_here_string
  | "cmd_subst" -> incr too_complex_cmd_subst
  | "proc_subst" -> incr too_complex_proc_subst
  | "subshell" -> incr too_complex_subshell
  | "arith_expansion" -> incr too_complex_arith_expansion
  | "control_flow" -> incr too_complex_control_flow
  | "function_def" -> incr too_complex_function_def
  | "glob_brace" -> incr too_complex_glob_brace
  | "background" -> incr too_complex_background
  | "parse_error" -> incr too_complex_parse_error
  | "__parse_aborted__" -> incr too_complex_parse_aborted
  | _ -> incr too_complex_other

let reset () =
  Atomic.set gate_diff_total 0;
  Atomic.set gate_diff_agree 0;
  Atomic.set gate_diff_legacy_allow_shadow_deny 0;
  Atomic.set gate_diff_legacy_deny_shadow_allow 0;
  Atomic.set gate_diff_shadow_cannot_parse 0;
  Atomic.set auto_bg_observed 0;
  Atomic.set auto_bg_would_have_promoted 0;
  Atomic.set too_complex_redirect 0;
  Atomic.set too_complex_logic_op 0;
  Atomic.set too_complex_heredoc 0;
  Atomic.set too_complex_here_string 0;
  Atomic.set too_complex_cmd_subst 0;
  Atomic.set too_complex_proc_subst 0;
  Atomic.set too_complex_subshell 0;
  Atomic.set too_complex_arith_expansion 0;
  Atomic.set too_complex_control_flow 0;
  Atomic.set too_complex_function_def 0;
  Atomic.set too_complex_glob_brace 0;
  Atomic.set too_complex_background 0;
  Atomic.set too_complex_parse_error 0;
  Atomic.set too_complex_parse_aborted 0;
  Atomic.set too_complex_other 0

type snapshot = {
  gate_diff_total : int;
  gate_diff_agree : int;
  gate_diff_legacy_allow_shadow_deny : int;
  gate_diff_legacy_deny_shadow_allow : int;
  gate_diff_shadow_cannot_parse : int;
  auto_bg_observed : int;
  auto_bg_would_have_promoted : int;
  too_complex_redirect : int;
  too_complex_logic_op : int;
  too_complex_heredoc : int;
  too_complex_here_string : int;
  too_complex_cmd_subst : int;
  too_complex_proc_subst : int;
  too_complex_subshell : int;
  too_complex_arith_expansion : int;
  too_complex_control_flow : int;
  too_complex_function_def : int;
  too_complex_glob_brace : int;
  too_complex_background : int;
  too_complex_parse_error : int;
  too_complex_parse_aborted : int;
  too_complex_other : int;
}

let snapshot () =
  {
    gate_diff_total = Atomic.get gate_diff_total;
    gate_diff_agree = Atomic.get gate_diff_agree;
    gate_diff_legacy_allow_shadow_deny =
      Atomic.get gate_diff_legacy_allow_shadow_deny;
    gate_diff_legacy_deny_shadow_allow =
      Atomic.get gate_diff_legacy_deny_shadow_allow;
    gate_diff_shadow_cannot_parse =
      Atomic.get gate_diff_shadow_cannot_parse;
    auto_bg_observed = Atomic.get auto_bg_observed;
    auto_bg_would_have_promoted = Atomic.get auto_bg_would_have_promoted;
    too_complex_redirect = Atomic.get too_complex_redirect;
    too_complex_logic_op = Atomic.get too_complex_logic_op;
    too_complex_heredoc = Atomic.get too_complex_heredoc;
    too_complex_here_string = Atomic.get too_complex_here_string;
    too_complex_cmd_subst = Atomic.get too_complex_cmd_subst;
    too_complex_proc_subst = Atomic.get too_complex_proc_subst;
    too_complex_subshell = Atomic.get too_complex_subshell;
    too_complex_arith_expansion = Atomic.get too_complex_arith_expansion;
    too_complex_control_flow = Atomic.get too_complex_control_flow;
    too_complex_function_def = Atomic.get too_complex_function_def;
    too_complex_glob_brace = Atomic.get too_complex_glob_brace;
    too_complex_background = Atomic.get too_complex_background;
    too_complex_parse_error = Atomic.get too_complex_parse_error;
    too_complex_parse_aborted = Atomic.get too_complex_parse_aborted;
    too_complex_other = Atomic.get too_complex_other;
  }

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    ("gate_diff_total", `Int s.gate_diff_total);
    ("gate_diff_agree", `Int s.gate_diff_agree);
    ("gate_diff_legacy_allow_shadow_deny",
     `Int s.gate_diff_legacy_allow_shadow_deny);
    ("gate_diff_legacy_deny_shadow_allow",
     `Int s.gate_diff_legacy_deny_shadow_allow);
    ("gate_diff_shadow_cannot_parse",
     `Int s.gate_diff_shadow_cannot_parse);
    ("auto_bg_observed", `Int s.auto_bg_observed);
    ("auto_bg_would_have_promoted", `Int s.auto_bg_would_have_promoted);
    ("too_complex_redirect", `Int s.too_complex_redirect);
    ("too_complex_logic_op", `Int s.too_complex_logic_op);
    ("too_complex_heredoc", `Int s.too_complex_heredoc);
    ("too_complex_here_string", `Int s.too_complex_here_string);
    ("too_complex_cmd_subst", `Int s.too_complex_cmd_subst);
    ("too_complex_proc_subst", `Int s.too_complex_proc_subst);
    ("too_complex_subshell", `Int s.too_complex_subshell);
    ("too_complex_arith_expansion", `Int s.too_complex_arith_expansion);
    ("too_complex_control_flow", `Int s.too_complex_control_flow);
    ("too_complex_function_def", `Int s.too_complex_function_def);
    ("too_complex_glob_brace", `Int s.too_complex_glob_brace);
    ("too_complex_background", `Int s.too_complex_background);
    ("too_complex_parse_error", `Int s.too_complex_parse_error);
    ("too_complex_parse_aborted", `Int s.too_complex_parse_aborted);
    ("too_complex_other", `Int s.too_complex_other);
  ]

let safe_ratio ~num ~den =
  if den <= 0 then 0.0
  else float_of_int num /. float_of_int den

let disagree_ratio (s : snapshot) : float =
  safe_ratio
    ~num:(s.gate_diff_legacy_allow_shadow_deny
          + s.gate_diff_legacy_deny_shadow_allow)
    ~den:s.gate_diff_total

let shadow_parse_coverage (s : snapshot) : float =
  if s.gate_diff_total <= 0 then 0.0
  else
    1.0
    -. safe_ratio
         ~num:s.gate_diff_shadow_cannot_parse
         ~den:s.gate_diff_total

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
           ("disagree_ratio", `Float (disagree_ratio s));
           ("shadow_parse_coverage", `Float (shadow_parse_coverage s));
           ("auto_bg_promotion_rate", `Float (auto_bg_promotion_rate s));
         ]);
      ])
  | other -> other
