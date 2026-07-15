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
}

let claim_scope_exclusions_to_json (e : claim_scope_exclusions) : Yojson.Safe.t =
  `Assoc
    [ "scope_excluded_count", `Int e.scope_excluded_count
    ; "blocked_count", `Int e.blocked_count
    ; "verification_blocked_count", `Int e.verification_blocked_count
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

let is_nonprogress (outcome : t option) : bool =
  match outcome with
  | Some (No_progress _ | Error _) -> true
  | Some Progress | None -> false
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
                Some
                  (No_progress
                     { reason =
                         No_eligible_tasks
                           { scope_excluded_count = get_int "scope_excluded_count"
                           ; blocked_count = get_int "blocked_count"
                           ; verification_blocked_count = get_int "verification_blocked_count"
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
