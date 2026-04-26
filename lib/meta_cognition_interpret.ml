(** Meta_cognition_interpret — Salience interpretation engine.

    Takes a parsed summary_input and determines the primary salience
    (stable, contested, tension, desire, stagnant) with supporting
    evidence and human-readable reasons.

    @since God file decomposition — extracted from meta_cognition.ml *)

open Meta_cognition_types

let operator_actionability = function
  | Some
      ("operator" | "operator_or_platform" | "operator_or_scheduler" | "room_or_operator")
    -> true
  | _ -> false
;;

let evidence_refs_of_belief (belief : belief_summary) =
  unique_non_empty (belief.evidence_refs @ belief.challenge_refs)
;;

let evidence_refs_of_salience (summary : summary_input) = function
  | Contested_belief ->
    (match summary.dominant_belief with
     | Some belief -> evidence_refs_of_belief belief
     | None -> [])
  | Operator_tension ->
    (match summary.top_tension with
     | Some tension -> tension.evidence_refs
     | None -> [])
  | Operator_desire ->
    (match summary.top_desire with
     | Some desire -> desire.evidence_refs
     | None -> [])
  | Stagnant_room ->
    (match summary.top_tension, summary.dominant_belief, summary.top_desire with
     | Some tension, _, _ when tension.evidence_refs <> [] -> tension.evidence_refs
     | _, Some belief, _ when evidence_refs_of_belief belief <> [] ->
       evidence_refs_of_belief belief
     | _, _, Some desire -> desire.evidence_refs
     | _ -> [])
  | Stable -> []
;;

let reason_of_salience (summary : summary_input) = function
  | Contested_belief ->
    (match Option.bind summary.dominant_belief (fun belief -> belief.claim) with
     | Some claim -> Printf.sprintf "집단 인식에 이견이 있습니다: %s" claim
     | None -> "집단 인식에 이견이 있습니다.")
  | Operator_tension ->
    (match Option.bind summary.top_tension (fun tension -> tension.topic) with
     | Some topic -> Printf.sprintf "운영자 개입이 필요한 집단 긴장: %s" topic
     | None -> "운영자 개입이 필요한 집단 긴장이 감지되었습니다.")
  | Operator_desire ->
    (match Option.bind summary.top_desire (fun desire -> desire.desired_state) with
     | Some desired_state -> Printf.sprintf "room이 운영자 액션을 원합니다: %s" desired_state
     | None -> "room-level desire가 운영자 액션을 요청합니다.")
  | Stagnant_room ->
    Printf.sprintf
      "room stagnation이 %.0f%%로 높습니다. 메타인지 snapshot을 확인하세요."
      (summary.stagnation_score *. 100.0)
  | Stable -> "room-level signal is currently stable."
;;

let target_id_of_salience (summary : summary_input) = function
  | Contested_belief -> Option.bind summary.dominant_belief (fun belief -> belief.id)
  | Operator_tension -> Option.bind summary.top_tension (fun tension -> tension.id)
  | Operator_desire -> Option.bind summary.top_desire (fun desire -> desire.id)
  | Stagnant_room | Stable -> None
;;

let interpret (summary : summary_input) =
  let signals =
    [ Contested_belief, summary.contested_belief_count > 0
    ; ( Operator_tension
      , match summary.top_tension with
        | Some tension -> tension.needs_operator || tension.severity = Some "high"
        | None -> false )
    ; ( Operator_desire
      , match summary.top_desire with
        | Some desire -> operator_actionability desire.actionability
        | None -> false )
    ; Stagnant_room, summary.stagnation_score >= 0.65
    ]
    |> List.filter_map (fun (salience, active) -> if active then Some salience else None)
  in
  let primary_salience =
    match signals with
    | salience :: _ -> salience
    | [] -> Stable
  in
  let secondary_saliences =
    match signals with
    | [] -> []
    | _primary :: rest -> rest
  in
  { primary_salience
  ; secondary_saliences
  ; reason = reason_of_salience summary primary_salience
  ; target_id = target_id_of_salience summary primary_salience
  ; evidence_refs = evidence_refs_of_salience summary primary_salience |> unique_non_empty
  }
;;

let salience_list_to_json saliences =
  `List (List.map (fun salience -> `String (salience_to_string salience)) saliences)
;;

let interpretation_to_json interpretation =
  `Assoc
    [ "primary_salience", `String (salience_to_string interpretation.primary_salience)
    ; "secondary_saliences", salience_list_to_json interpretation.secondary_saliences
    ; "reason", `String interpretation.reason
    ; ( "target_id"
      , match interpretation.target_id with
        | Some value -> `String value
        | None -> `Null )
    ; ( "evidence_refs"
      , `List (List.map (fun ref_id -> `String ref_id) interpretation.evidence_refs) )
    ]
;;

let summary_signature summary =
  let dominant_belief = summary.dominant_belief in
  let top_tension = summary.top_tension in
  let top_desire = summary.top_desire in
  let stagnation_bucket = int_of_float (summary.stagnation_score *. 10.0) in
  let parts =
    [ Option.value ~default:"none" (Option.bind dominant_belief (fun belief -> belief.id))
    ; Option.value
        ~default:"none"
        (Option.bind dominant_belief (fun belief -> belief.status))
    ; Option.value ~default:"none" (Option.bind top_tension (fun tension -> tension.id))
    ; Option.value
        ~default:"none"
        (Option.bind top_tension (fun tension -> tension.severity))
    ; Option.value ~default:"none" (Option.bind top_desire (fun desire -> desire.id))
    ; Option.value
        ~default:"none"
        (Option.bind top_desire (fun desire -> desire.actionability))
    ; string_of_int summary.contested_belief_count
    ; string_of_int stagnation_bucket
    ]
  in
  Digest.string (String.concat "|" parts) |> Digest.to_hex
;;
