(** Keeper_routine_allowlist — code-defined auto-approval rules for keeper
    autonomous task lifecycle. See keeper_routine_allowlist.mli for rationale. *)

module RL = Keeper_approval_queue

(* ── Action extraction ───────────────────────────────────── *)

(** Extract a routine action from a tool input JSON.

    Tools in the allowlist use either an [op] key (keeper_shell,
    keeper_bash) or an [action] key (masc_transition family); we
    accept both so a single rule type can describe both surfaces.
    Prefer [op] when it is present because shell execution semantics
    come from [op], and an unrelated [action] key must not be able to
    mask a dangerous shell op. *)
let action_of_input (input : Yojson.Safe.t) : string option =
  let trimmed_lc raw =
    let s = String.trim raw in
    if s = "" then None else Some (String.lowercase_ascii s)
  in
  match input with
  | `Assoc fields ->
    let read key =
      match List.assoc_opt key fields with
      | Some (`String s) -> trimmed_lc s
      | _ -> None
    in
    (match read "op" with
     | Some _ as found -> found
     | None -> read "action")
  | _ -> None
;;

(* ── Static rule table ────────────────────────────────────── *)

(** Tool-specific allowlist rule. Each rule encodes:
    - which tool name it applies to;
    - the maximum risk level at which it auto-approves;
    - an optional set of routine action/op strings. For shell-like tools
      [op] is authoritative; otherwise [action] is used. [None] means
      "any input is allowed up to [max_risk]" (no action discrimination
      needed);
    - a short human-readable label for audit logs. *)
type rule =
  { tool : string
  ; max_risk : RL.risk_level
  ; allowed_actions : string list option
  ; label : string
  }

(** Allowlist rules. KEEP THIS LIST NARROW.

    Adding entries here changes governance policy. Do not allowlist:
    - destructive force_* actions (these are classified Critical via
      "force" pattern and stopped by [auto_approval_forbidden] anyway,
      but listing them here would be a defense-in-depth hole);
    - shell or git tools except exact, op-backed keeper routines such as
      [keeper_shell op=git_clone];
    - high/critical-risk tools.
    *)
let rules : rule list =
  [ (* masc_transition: keeper task lifecycle. Only the routine actions
       are allowlisted. cancel and force_* are intentionally excluded. *)
    { tool = "masc_transition"
    ; max_risk = RL.Medium
    ; allowed_actions = Some [ "claim"; "start"; "heartbeat"; "done"; "release" ]
    ; label = "keeper_routine.masc_transition"
    }
  ; (* keeper_board_post: routine status posts. Up to Medium risk
       auto-approves. High/Critical still require operator approval. *)
    { tool = "keeper_board_post"
    ; max_risk = RL.Medium
    ; allowed_actions = None
    ; label = "keeper_routine.keeper_board_post"
    }
  ; (* Keeper-side task lifecycle helpers (counterpart to masc_transition
       on the keeper tool surface). These are the standard autonomous
       flow used by long-running keepers. *)
    { tool = "keeper_task_claim"
    ; max_risk = RL.Medium
    ; allowed_actions = None
    ; label = "keeper_routine.keeper_task_claim"
    }
  ; { tool = "keeper_task_done"
    ; max_risk = RL.Medium
    ; allowed_actions = None
    ; label = "keeper_routine.keeper_task_done"
    }
  ; { tool = "keeper_task_submit_for_verification"
    ; max_risk = RL.Medium
    ; allowed_actions = None
    ; label = "keeper_routine.keeper_task_submit_for_verification"
    }
  ; (* PR-E (Plan v3 Leak 3): keeper_shell op=git_clone is the canonical
       way for a keeper to bring its work tree into the docker sandbox.
       Without this rule the [keeper_shell] tool name itself trips
       Governance.destructive_tool_or_op (the "shell" substring filter)
       and every git_clone is queued for operator approval, even though
       the [op] is one of the safest possible.  Narrow the allowlist to
       just [op=git_clone]; force_*, sh -c, and write-side ops still
       pass through the standard approval path. *)
    { tool = "keeper_shell"
    ; max_risk = RL.Medium
    ; allowed_actions = Some [ "git_clone" ]
    ; label = "keeper_routine.keeper_shell.git_clone"
    }
  ]
;;

(* ── Matching ─────────────────────────────────────────────── *)

let action_matches (rule : rule) (input : Yojson.Safe.t) : bool =
  match rule.allowed_actions with
  | None -> true
  | Some allowed ->
    (match action_of_input input with
     | None -> false
     | Some action -> List.mem action allowed)
;;

let find_rule ~tool_name ~input ~risk_level : rule option =
  List.find_opt
    (fun rule ->
       String.equal rule.tool tool_name
       && RL.risk_level_to_int risk_level <= RL.risk_level_to_int rule.max_risk
       && action_matches rule input)
    rules
;;

let matches ~tool_name ~input ~risk_level =
  Option.is_some (find_rule ~tool_name ~input ~risk_level)
;;

let rule_label ~tool_name ~input ~risk_level =
  Option.map (fun (rule : rule) -> rule.label) (find_rule ~tool_name ~input ~risk_level)
;;

(* ── Observability ────────────────────────────────────────── *)

let rule_to_yojson (rule : rule) : Yojson.Safe.t =
  let actions_json =
    match rule.allowed_actions with
    | None -> `String "*"
    | Some xs -> `List (List.map (fun a -> `String a) xs)
  in
  `Assoc
    [ "tool", `String rule.tool
    ; "max_risk", `String (RL.risk_level_to_string rule.max_risk)
    ; "allowed_actions", actions_json
    ; "label", `String rule.label
    ]
;;

let rules_summary () : Yojson.Safe.t = `List (List.map rule_to_yojson rules)
