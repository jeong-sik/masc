type code =
  | Activity_disabled
  | Activity_unobserved
  | Workspace_precondition_failed
  | Worker_unavailable
  | Outcome_unknown
[@@deriving enumerate]

let code_to_wire = function
  | Activity_disabled -> "activity_disabled"
  | Activity_unobserved -> "activity_unobserved"
  | Workspace_precondition_failed -> "workspace_precondition_failed"
  | Worker_unavailable -> "worker_unavailable"
  | Outcome_unknown -> "outcome_unknown"
;;

let code_of_wire wire =
  List.find_opt (fun code -> String.equal (code_to_wire code) wire) all_of_code
;;

type refusal = { code : code option; message : string option }

let encode ?code message : Yojson.Safe.t =
  let code = match code with
    | None -> []
    | Some code -> [ "code", `String (code_to_wire code) ] in
  `Assoc (code @ [ "ok", `Bool false; "message", `String message ])
;;

let ( let* ) = Result.bind

let decode : Yojson.Safe.t -> (refusal, string) result = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "refusal has repeated fields"
    else (
      match List.assoc_opt "ok" fields with
      | Some (`Bool false) ->
        let* code =
          match List.assoc_opt "code" fields with
          | None -> Ok None
          | Some (`String wire) ->
            (match code_of_wire wire with
             | Some code -> Ok (Some code)
             | None -> Error (Printf.sprintf "refusal code %S is not known" wire))
          | Some _ -> Error "refusal code must be a string" in
        let* message =
          match List.assoc_opt "message" fields with
          | None -> Ok None
          | Some (`String message) -> Ok (Some message)
          | Some _ -> Error "refusal message must be a string" in
        Ok { code; message }
      | Some _ | None -> Error "body is not a refusal (ok=false is required)")
  | _ -> Error "refusal body must be an object"
;;
