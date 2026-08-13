type failure_status =
  | Mismatch
  | Unobserved

type violation =
  | Effective_resolution_unavailable
  | Config_effective_mismatch
  | Receipt_evidence_unavailable
  | Effective_receipt_mismatch

type verification =
  | Verified of { containment : string }
  | Not_verified of
      { status : failure_status
      ; violation : violation
      ; detail : string
      }

type observation =
  | Absent
  | Observed of
      { descriptor : Yojson.Safe.t
      ; verification : verification
      }
  | Invalid_descriptor of
      { descriptor : Yojson.Safe.t
      ; detail : string
      }

type attention =
  { reason : string
  ; next_human_action : string
  }

let nonempty_string field json =
  match Json_util.assoc_string_opt field json with
  | Some value when String.trim value <> "" -> Ok value
  | Some _ | None -> Error (field ^ " must be a non-empty string")
;;

let violation_of_string = function
  | "effective_resolution_unavailable" -> Some Effective_resolution_unavailable
  | "config_effective_mismatch" -> Some Config_effective_mismatch
  | "receipt_evidence_unavailable" -> Some Receipt_evidence_unavailable
  | "effective_receipt_mismatch" -> Some Effective_receipt_mismatch
  | _ -> None
;;

let violation_to_string = function
  | Effective_resolution_unavailable -> "effective_resolution_unavailable"
  | Config_effective_mismatch -> "config_effective_mismatch"
  | Receipt_evidence_unavailable -> "receipt_evidence_unavailable"
  | Effective_receipt_mismatch -> "effective_receipt_mismatch"
;;

let violation_matches_status status violation =
  match status, violation with
  | ( Mismatch
    , (Config_effective_mismatch | Effective_receipt_mismatch) )
  | ( Unobserved
    , (Effective_resolution_unavailable | Receipt_evidence_unavailable) ) ->
    true
  | (Mismatch, (Effective_resolution_unavailable | Receipt_evidence_unavailable))
  | (Unobserved, (Config_effective_mismatch | Effective_receipt_mismatch)) ->
    false
;;

let decode_verification descriptor =
  match Json_util.assoc_string_opt "schema" descriptor with
  | Some "masc.keeper.sandbox-routing.v1" ->
    (match Json_util.assoc_member_opt "verification" descriptor with
     | None -> Error "verification object is missing"
     | Some verification ->
       (match nonempty_string "status" verification with
        | Error _ as error -> error
        | Ok "verified" ->
          (match nonempty_string "containment" verification with
           | Ok "not_verified" ->
             Error "verified routing cannot use containment=not_verified"
           | Ok containment -> Ok (Verified { containment })
           | Error _ as error -> error)
        | Ok ("mismatch" as status) | Ok ("unobserved" as status) ->
          (match nonempty_string "containment" verification with
           | Ok "not_verified" ->
             (match
                nonempty_string "violation" verification,
                nonempty_string "detail" verification
              with
              | Ok violation_wire, Ok detail ->
                let status =
                  if String.equal status "mismatch" then Mismatch else Unobserved
                in
                (match violation_of_string violation_wire with
                 | Some violation when violation_matches_status status violation ->
                   Ok (Not_verified { status; violation; detail })
                 | Some _ ->
                   Error
                     "sandbox routing violation is inconsistent with verification status"
                 | None ->
                   Error
                     ("unknown sandbox routing violation: " ^ violation_wire))
              | Error error, _ | _, Error error -> Error error)
           | Ok containment ->
             Error
               (Printf.sprintf
                  "%s routing must use containment=not_verified, got %s"
                  status
                  containment)
           | Error _ as error -> error)
        | Ok status ->
          Error ("unknown sandbox routing verification status: " ^ status)))
  | Some schema -> Error ("unknown sandbox routing descriptor schema: " ^ schema)
  | None -> Error "sandbox routing descriptor schema is missing"
;;

let of_receipt receipt =
  match Json_util.assoc_member_opt "sandbox" receipt with
  | None -> Absent
  | Some sandbox ->
    (match Json_util.assoc_member_opt "routing" sandbox with
     | None | Some `Null -> Absent
     | Some descriptor ->
       (match decode_verification descriptor with
        | Ok verification -> Observed { descriptor; verification }
        | Error detail -> Invalid_descriptor { descriptor; detail }))
;;

let descriptor_to_yojson = function
  | Absent -> `Null
  | Observed { descriptor; _ }
  | Invalid_descriptor { descriptor; _ } ->
    descriptor
;;

let next_human_action = "inspect_sandbox_routing_evidence"

let attention = function
  | Absent | Observed { verification = Verified _; _ } -> None
  | Observed
      { verification = Not_verified { violation; _ }; _ } ->
    Some
      { reason = "sandbox_routing_" ^ violation_to_string violation
      ; next_human_action
      }
  | Invalid_descriptor _ ->
    Some
      { reason = "sandbox_routing_descriptor_invalid"
      ; next_human_action
      }
;;

let attention_to_yojson = function
  | None -> `Null
  | Some attention ->
    `Assoc
      [ "needs_attention", `Bool true
      ; "reason", `String attention.reason
      ; "next_human_action", `String attention.next_human_action
      ]
;;
