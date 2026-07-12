type verdict =
  | Resume_with_guidance of
      { guidance : string
      ; rationale : string
      }
  | Escalate_to_operator of { rationale : string }

let wire_decision = "decision"
let wire_guidance = "guidance"
let wire_rationale = "rationale"
let wire_resume_with_guidance = "resume_with_guidance"
let wire_escalate_to_operator = "escalate_to_operator"

let decision_tokens = [ wire_resume_with_guidance; wire_escalate_to_operator ]

let decision_label = function
  | Resume_with_guidance _ -> wire_resume_with_guidance
  | Escalate_to_operator _ -> wire_escalate_to_operator
;;

let rationale = function
  | Resume_with_guidance { rationale; _ }
  | Escalate_to_operator { rationale } ->
    rationale
;;

let guidance = function
  | Resume_with_guidance { guidance; _ } -> Some guidance
  | Escalate_to_operator _ -> None
;;

let ( let* ) = Result.bind

let exact_fields fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected =
    [ wire_decision; wire_guidance; wire_rationale ] |> List.sort String.compare
  in
  if actual = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "failure judgment object fields must be exactly [%s], got [%s]"
         (String.concat "," expected)
         (String.concat "," actual))
;;

let required_nonempty_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value ""
    then Error (Printf.sprintf "failure judgment %s must not be empty" name)
    else Ok value
  | Some _ -> Error (Printf.sprintf "failure judgment %s must be a string" name)
  | None -> Error (Printf.sprintf "failure judgment %s is required" name)
;;

let of_yojson = function
  | `Assoc fields ->
    let* () = exact_fields fields in
    let* decision = required_nonempty_string fields wire_decision in
    let* rationale = required_nonempty_string fields wire_rationale in
    (match decision, List.assoc_opt wire_guidance fields with
     | decision, Some (`String guidance)
       when String.equal decision wire_resume_with_guidance ->
       let guidance = String.trim guidance in
       if String.equal guidance ""
       then Error "failure judgment resume guidance must not be empty"
       else Ok (Resume_with_guidance { guidance; rationale })
     | decision, Some `Null when String.equal decision wire_escalate_to_operator ->
       Ok (Escalate_to_operator { rationale })
     | decision, _ when String.equal decision wire_resume_with_guidance ->
       Error "failure judgment resume guidance must be a string"
     | decision, _ when String.equal decision wire_escalate_to_operator ->
       Error "failure judgment operator escalation guidance must be null"
     | unknown, _ ->
       Error (Printf.sprintf "unknown failure judgment decision: %s" unknown))
  | _ -> Error "failure judgment response must be an object"
;;

let to_yojson verdict =
  let guidance_json =
    match guidance verdict with
    | Some value -> `String value
    | None -> `Null
  in
  `Assoc
    [ wire_decision, `String (decision_label verdict)
    ; wire_guidance, guidance_json
    ; wire_rationale, `String (rationale verdict)
    ]
;;
