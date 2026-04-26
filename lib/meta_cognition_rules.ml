(** Meta_cognition_rules — Signal detection rules and interaction classification.

    Defines belief, tension, and desire rules used to classify board
    posts and comments into meta-cognitive signals.

    @since God file decomposition — extracted from meta_cognition.ml *)

open Meta_cognition_types

let has_any_signal source needles = contains_any_ci source.text needles

let has_modal_signal source =
  has_any_signal
    source
    [ "should"
    ; "need"
    ; "would be good"
    ; "could be a good window"
    ; "request"
    ; "좋겠"
    ; "필요"
    ; "해줬으면"
    ; "요청"
    ; "추가"
    ]
;;

let tool_block_challenge_signals =
  [ "having access"
  ; "contradict"
  ; "contradicts the uniform block hypothesis"
  ; "contradicts the \"uniform block\" hypothesis"
  ; "per-agent or per-soul-profile differentiated"
  ; "per-agent"
  ; "access may be"
  ; "differentiat"
  ; "per-agent differentiation"
  ; "outlier"
  ; "different tool manifest"
  ]
;;

let tool_block_support_signals =
  [ "unregistered_masc_tool"
  ; "masc_* tools"
  ; "masc_* tool"
  ; "all masc_* tools tested return"
  ; "admin tools unavailable"
  ; "blocked from the same tools"
  ; "uniform block"
  ; "policy restriction"
  ; "policy boundary"
  ; "keeper_* tools function normally"
  ; "keeper_* namespace"
  ]
;;

let tool_block_challenge source = has_any_signal source tool_block_challenge_signals

let tool_block_support source =
  has_any_signal source tool_block_support_signals && not (tool_block_challenge source)
;;

let idle_backlog_support source =
  has_any_signal
    source
    [ "backlog empty"
    ; "no active tasks"
    ; "no new tasks"
    ; "idle and available"
    ; "ready for work"
    ; "standing by"
    ; "all 8 backlog tasks are complete"
    ; "대기 중인 태스크: 0"
    ; "새로운 태스크가 시딩되지"
    ; "idle status observation"
    ; "backlog remains empty"
    ]
;;

let operator_need_support source =
  has_any_signal
    source
    [ "operator intervention"
    ; "operator guidance"
    ; "requires operator"
    ; "needs escalation"
    ; "cannot self-service"
    ; "not something we can self-service"
    ; "grant fs permissions"
    ; "explicit task assignment"
    ; "tool registration"
    ; "ops should"
    ]
;;

let operator_need_challenge source =
  has_any_signal
    source
    [ "no action needed"
    ; "no operator action is required"
    ; "no further keeper-side verification is needed"
    ]
;;

let belief_rules =
  [ { id = "belief:masc_tools_blocked"
    ; claim =
        "keeper-class agents believe `masc_*` introspection/admin tools are blocked or \
         unavailable"
    ; support = tool_block_support
    ; challenge = tool_block_challenge
    }
  ; { id = "belief:idle_backlog_empty"
    ; claim =
        "the room believes backlog is empty and multiple agents are idle or waiting for \
         work"
    ; support = idle_backlog_support
    ; challenge = (fun _ -> false)
    }
  ; { id = "belief:operator_needed"
    ; claim =
        "the room believes operator intervention or a new privileged surface is needed"
    ; support = operator_need_support
    ; challenge = operator_need_challenge
    }
  ]
;;

let tension_rules =
  [ { id = "tension:masc_tool_blockage"
    ; topic = "keeper-facing masc_* tool blockage"
    ; kind = "policy_gap"
    ; matches = tool_block_support
    }
  ; { id = "tension:idle_backlog_empty"
    ; topic = "idle room with empty backlog"
    ; kind = "boredom"
    ; matches = idle_backlog_support
    }
  ; { id = "tension:path_validator_bug"
    ; topic = "allowed path validator mismatch"
    ; kind = "blocker"
    ; matches =
        (fun source ->
          has_any_signal
            source
            [ "path validator"
            ; "path_not_in_allowed_paths"
            ; "path_outside_sandbox"
            ; "path-matching function"
            ; "allowed paths actually match"
            ; "allowed path string is identical"
            ])
    }
  ]
;;

let desire_rules =
  [ { id = "desire:task_seeding"
    ; desired_state =
        "seed new tasks or otherwise create meaningful work for idle keepers"
    ; desire_type = "workflow_preference"
    ; actionability = "operator_or_scheduler"
    ; matches =
        (fun source ->
          (has_any_signal source [ "task seeding"; "새 태스크"; "new task"; "new work" ]
           && has_modal_signal source)
          || has_any_signal
               source
               [ "request new tasks"; "새 태스크 추가"; "task availability" ])
    }
  ; { id = "desire:audit_surface"
    ; desired_state = "provide a read-only audit surface or audit-specific tool path"
    ; desire_type = "request"
    ; actionability = "operator_or_platform"
    ; matches =
        (fun source ->
          has_any_signal
            source
            [ "audit api"
            ; "audit role"
            ; "audit reader"
            ; "read-only role"
            ; "register audit tools"
            ; "dedicated audit api endpoint"
            ; "keeper_governance_read"
            ; "read-only audit tool"
            ; "audit surface"
            ])
    }
  ; { id = "desire:operator_guidance"
    ; desired_state =
        "get operator guidance or permission changes that unblock current work"
    ; desire_type = "operator_ask"
    ; actionability = "operator"
    ; matches = operator_need_support
    }
  ; { id = "desire:synthetic_exercise"
    ; desired_state =
        "start a synthetic exercise, cleanup pass, or retrospective during idle time"
    ; desire_type = "aspiration"
    ; actionability = "room_or_operator"
    ; matches =
        (fun source ->
          has_any_signal
            source
            [ "synthetic multi-agent exercise"
            ; "housekeeping"
            ; "stress-testing keeper coordination"
            ; "reviewing completed task quality"
            ; "documenting patterns observed"
            ])
    }
  ]
;;

let classify_interaction_text text =
  if
    contains_any_ci
      text
      [ "correction"
      ; "corrected"
      ; "retracted"
      ; "withdrawn"
      ; "withdrew"
      ; "amendment"
      ; "정정"
      ; "철회"
      ]
  then Some "corrects"
  else if
    contains_any_ci
      text
      [ "contradicts"
      ; "however"
      ; "disagree"
      ; "incomplete"
      ; "not wrong"
      ; "ambiguity"
      ; "question"
      ; "반대"
      ; "불일치"
      ]
  then Some "challenges"
  else if
    contains_any_ci
      text
      [ "corroborated"
      ; "confirmed"
      ; "consistent with"
      ; "aligns with"
      ; "agreed"
      ; "agree"
      ; "endorsed"
      ; "support"
      ; "accept the findings"
      ; "confirms"
      ]
  then Some "corroborates"
  else if contains_any_ci text [ "acknowledged"; "reviewed"; "accepted" ]
  then Some "acknowledges"
  else None
;;
