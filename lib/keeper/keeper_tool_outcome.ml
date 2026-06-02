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
  all_goals_excluded : bool;
}

let claim_scope_exclusions_to_json (e : claim_scope_exclusions) : Yojson.Safe.t =
  `Assoc
    [ "scope_excluded_count", `Int e.scope_excluded_count
    ; "blocked_count", `Int e.blocked_count
    ; "verification_blocked_count", `Int e.verification_blocked_count
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

let of_json (json : Yojson.Safe.t) : t option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "Progress") -> Some Progress
     | Some (`String "No_progress") ->
       (match List.assoc_opt "reason" fields with
        | Some (`Assoc reason_fields) ->
          (match List.assoc_opt "kind" reason_fields with
           | Some (`String "No_eligible_tasks") ->
             (match List.assoc_opt "exclusions" reason_fields with
              | Some (`Assoc exc_fields) ->
                let get_int key =
                  match List.assoc_opt key exc_fields with
                  | Some (`Int n) -> n
                  | _ -> 0
                in
                let get_bool key =
                  match List.assoc_opt key exc_fields with
                  | Some (`Bool b) -> b
                  | _ -> false
                in
                Some
                  (No_progress
                     { reason =
                         No_eligible_tasks
                           { scope_excluded_count = get_int "scope_excluded_count"
                           ; blocked_count = get_int "blocked_count"
                           ; verification_blocked_count = get_int "verification_blocked_count"
                           ; all_goals_excluded = get_bool "all_goals_excluded"
                           }
                     })
              | _ -> None)
           | Some (`String "Resource_conflict") ->
             (match List.assoc_opt "resource" reason_fields with
              | Some (`String resource) ->
                Some (No_progress { reason = Resource_conflict { resource } })
              | _ -> None)
           | Some (`String "No_work_available") ->
             Some (No_progress { reason = No_work_available })
           | _ -> None)
        | _ -> None)
     | Some (`String "Error") ->
       (match List.assoc_opt "reason" fields with
        | Some (`String reason) -> Some (Error { reason })
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let strip_from_json (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (k, _) -> not (String.equal k "typed_outcome")) fields)
  | json -> json
;;

(* Closed set of [no_work_reason] arguments the keeper_stay_silent tool accepts
   as a typed no-work proof. The strings are the JSON-schema enum surfaced to the
   model; each maps to a [No_progress] outcome that lets a stay_silent-under-signal
   turn complete (see Keeper_tool_progress.actionable_tool_contract_violation_reason).
   Unknown / absent values return [None] (anti-pattern #2: unknown is not a
   permissive default), so a bare or malformed stay_silent stays a contract
   violation under an actionable signal. The variant is reused rather than a
   dedicated [Deliberate_no_fit]: the gate only reads "proof present?", reuse adds
   no parser surface to [of_json] (a hand-written string match where a missed arm
   would silently drop the proof), and the only branching consumer
   (Keeper_tool_progress line ~242) treats No_work_available benignly. The
   semantic gap ("signal present, no fit" vs "no work exists") is documented here
   and in the RFC rather than encoded as a new variant. *)
let stay_silent_no_work_reasons : string list =
  [ "no_actionable_fit"; "no_eligible_work"; "deferred_to_other_keeper" ]
;;

let no_work_reason_of_stay_silent_arg (reason : string) : t option =
  let reason = String.trim reason in
  if List.mem reason stay_silent_no_work_reasons
  then Some (No_progress { reason = No_work_available })
  else None
;;
