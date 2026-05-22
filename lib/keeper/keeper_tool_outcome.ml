type t =
  | Progress
  | No_progress of { reason : no_progress_reason }
  | Error of { reason : string }

and no_progress_reason =
  | No_eligible_tasks of claim_scope_exclusions
  | Resource_conflict of { resource : string }
  | No_work_available

and claim_scope_exclusions = {
  scope_excluded_count : int;
  blocked_count : int;
  verification_blocked_count : int;
  required_tool_excluded_count : int;
  all_goals_excluded : bool;
}

let claim_scope_exclusions_to_json (e : claim_scope_exclusions) : Yojson.Safe.t =
  `Assoc
    [ "scope_excluded_count", `Int e.scope_excluded_count
    ; "blocked_count", `Int e.blocked_count
    ; "verification_blocked_count", `Int e.verification_blocked_count
    ; "required_tool_excluded_count", `Int e.required_tool_excluded_count
    ; "all_goals_excluded", `Bool e.all_goals_excluded
    ]
;;

let to_json (outcome : t) : Yojson.Safe.t =
  match outcome with
  | Progress -> `Assoc [ "kind", `String "Progress" ]
  | No_progress { reason } ->
    let reason_json =
      match reason with
      | No_eligible_tasks exclusions ->
        `Assoc
          [ "kind", `String "No_eligible_tasks"
          ; "exclusions", claim_scope_exclusions_to_json exclusions
          ]
      | Resource_conflict { resource } ->
        `Assoc [ "kind", `String "Resource_conflict"; "resource", `String resource ]
      | No_work_available -> `Assoc [ "kind", `String "No_work_available" ]
    in
    `Assoc [ "kind", `String "No_progress"; "reason", reason_json ]
  | Error { reason } ->
    `Assoc [ "kind", `String "Error"; "reason", `String reason ]
;;
