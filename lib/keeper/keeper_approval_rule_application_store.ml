open Keeper_approval_queue_rules_types

type application =
  { approval_id : string
  ; resolution_sequence : int
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; expires_at : float option
  ; actor : string option
  }

type application_effect = Rule_applied | Superseded

type receipt =
  { application : application
  ; rule_id : string
  ; settlement : application_effect
  }

type t =
  { rules : approval_rule list
  ; applications : receipt list
  }

let empty = { rules = []; applications = [] }
open Result.Syntax
module Approval_ids = Set.Make (String)
module Resolution_sequences = Set.Make (Int)

let rule_identity_matches (left : approval_rule) (right : approval_rule) =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && String.equal left.request_fingerprint right.request_fingerprint
;;

let same_application left right =
  String.equal left.approval_id right.approval_id
  && Int.equal left.resolution_sequence right.resolution_sequence
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && String.equal left.request_fingerprint right.request_fingerprint
  && Option.equal Float.equal left.expires_at right.expires_at
  && Option.equal String.equal left.actor right.actor
;;

let validate_application application =
  if List.exists (fun value -> String.trim value = "")
       [ application.approval_id; application.keeper_name; application.tool_name
       ; application.request_fingerprint ]
  then Error "rule application identity must contain non-blank strings"
  else if application.resolution_sequence <= 0
  then Error "rule application requires a positive resolution sequence"
  else
    match application.expires_at with
    | Some value when not (Float.is_finite value) ->
      Error "rule application expiry must be finite or null"
    | Some _ | None -> Ok ()
;;

let find_application store ~approval_id =
  List.find_opt (fun receipt -> String.equal receipt.application.approval_id approval_id)
    store.applications
;;

let latest_application store application =
  List.fold_left (fun latest receipt ->
    let candidate = receipt.application in
    if String.equal candidate.keeper_name application.keeper_name
       && String.equal candidate.tool_name application.tool_name
       && String.equal candidate.request_fingerprint application.request_fingerprint
    then match latest with
      | None -> Some receipt
      | Some previous ->
        if candidate.resolution_sequence > previous.application.resolution_sequence
        then Some receipt else latest
    else latest) None store.applications
;;

let validate store =
  let rec rules seen = function
    | [] -> Ok ()
    | (rule : approval_rule) :: rest ->
      if (match rule.expires_at with Some value -> not (Float.is_finite value) | None -> false)
      then Error "approval rule expiry must be finite or null"
      else if List.exists (fun previous -> String.equal previous.id rule.id) seen
      then Error (Printf.sprintf "duplicate approval rule id %s" rule.id)
      else if List.exists (fun previous -> rule_identity_matches previous rule) seen
      then Error
        (Printf.sprintf "duplicate exact Always Allowed identity for keeper=%s operation=%s"
           rule.keeper_name rule.tool_name)
      else rules (rule :: seen) rest
  in
  let* () = rules [] store.rules in
  let rec applications seen sequences = function
    | [] -> Ok ()
    | receipt :: rest ->
      let application = receipt.application in
      let* () = validate_application application in
      if String.trim receipt.rule_id = "" then Error "rule application requires a rule id"
      else if Approval_ids.mem application.approval_id seen
      then Error ("duplicate rule application approval id " ^ application.approval_id)
      else if Resolution_sequences.mem application.resolution_sequence sequences
      then Error "duplicate rule application resolution sequence"
      else
        let* () =
          match List.find_opt (fun (rule : approval_rule) -> String.equal rule.id receipt.rule_id)
                  store.rules with
          | None -> Ok ()
          | Some rule ->
            if String.equal rule.keeper_name application.keeper_name
               && String.equal rule.tool_name application.tool_name
               && String.equal rule.request_fingerprint application.request_fingerprint
            then Ok ()
            else Error "rule application receipt does not match its rule identity"
        in
        applications (Approval_ids.add application.approval_id seen)
          (Resolution_sequences.add application.resolution_sequence sequences) rest
  in
  let* () = applications Approval_ids.empty Resolution_sequences.empty store.applications in
  let rec creation_receipts = function
    | [] -> Ok store
    | (rule : approval_rule) :: rest ->
      let* () = match rule.source_approval_id with
        | None -> Error "approval rule requires its creation approval identity"
        | Some approval_id ->
          (match find_application store ~approval_id with
           | Some { rule_id; settlement = Rule_applied; application }
             when String.equal rule_id rule.id
                  && Option.equal String.equal application.actor rule.created_by ->
             (match latest_application store application with
              | Some { rule_id; settlement = Rule_applied; application }
                when String.equal rule_id rule.id
                     && Option.equal Float.equal application.expires_at rule.expires_at -> Ok ()
              | Some { settlement = (Rule_applied | Superseded); _ } | None ->
                Error "approval rule differs from its latest applied resolution")
           | Some { settlement = (Rule_applied | Superseded); _ } | None ->
             Error "approval rule is missing its creation application receipt")
      in
      creation_receipts rest
  in
  creation_receipts store.rules
;;

let exact_fields expected fields =
  if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
  then Ok ()
  else Error "rule application store has missing, duplicate or unknown fields"
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None -> Error (key ^ " must be a non-blank string")
;;

let expiry_of_json = function
  | `Null -> Ok None
  | `Float value when Float.is_finite value -> Ok (Some value)
  | `Int value -> Ok (Some (float_of_int value))
  | `Float _ | `Bool _ | `String _ | `Intlit _ | `Assoc _ | `List _ ->
    Error "rule application expiry must be a finite number or null"
;;

let receipt_of_json = function
  | `Assoc fields ->
    let* () = exact_fields
      [ "approval_id"; "resolution_sequence"; "rule_id"; "settlement"; "keeper_name"; "tool_name"
      ; "request_fingerprint"; "expires_at"; "actor" ] fields in
    let* approval_id = required_string fields "approval_id" in
    let* resolution_sequence = match List.assoc "resolution_sequence" fields with
      | `Int sequence when sequence > 0 -> Ok sequence
      | _ -> Error "rule application requires a positive resolution sequence" in
    let* rule_id = required_string fields "rule_id" in
    let* settlement = match List.assoc "settlement" fields with
      | `String "applied" -> Ok Rule_applied
      | `String "superseded" -> Ok Superseded
      | _ -> Error "rule application settlement must be applied or superseded" in
    let* keeper_name = required_string fields "keeper_name" in
    let* tool_name = required_string fields "tool_name" in
    let* request_fingerprint = required_string fields "request_fingerprint" in
    let* expires_at = expiry_of_json (List.assoc "expires_at" fields) in
    let* actor =
      match List.assoc "actor" fields with
      | `Null -> Ok None
      | `String actor -> Ok (Some actor)
      | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
        Error "rule application actor must be a string or null"
    in
    Ok { rule_id; settlement; application =
      { approval_id; resolution_sequence; keeper_name; tool_name; request_fingerprint; expires_at; actor } }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "rule application receipt must be an object"
;;

let decode_list decode entries =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
      let* entry = decode entry in
      loop (entry :: acc) rest
  in
  loop [] entries
;;

let of_yojson = function
  | `Assoc fields ->
    let* () = exact_fields [ "schema_version"; "rules"; "applications" ] fields in
    (match List.assoc "schema_version" fields, List.assoc "rules" fields,
           List.assoc "applications" fields with
     | `Int 1, `List rules, `List applications ->
       let* rules = decode_list approval_rule_of_yojson_with_error rules in
       let* applications = decode_list receipt_of_json applications in
       validate { rules; applications }
     | _ -> Error "rule application store requires schema_version=1 and two lists")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "approval rules file requires the canonical versioned application store"
;;

let expiry_json = function Some value -> `Float value | None -> `Null

let receipt_to_json receipt =
  let application = receipt.application in
  `Assoc
    [ "approval_id", `String application.approval_id
    ; "resolution_sequence", `Int application.resolution_sequence
    ; "rule_id", `String receipt.rule_id
    ; "settlement", `String (match receipt.settlement with Rule_applied -> "applied" | Superseded -> "superseded")
    ; "keeper_name", `String application.keeper_name; "tool_name", `String application.tool_name
    ; "request_fingerprint", `String application.request_fingerprint
    ; "expires_at", expiry_json application.expires_at
    ; "actor", (match application.actor with Some actor -> `String actor | None -> `Null) ]
;;

let to_yojson store =
  `Assoc
    [ "schema_version", `Int 1
    ; "rules", `List (List.map approval_rule_to_yojson store.rules)
    ; "applications", `List (List.map receipt_to_json store.applications) ]
;;
