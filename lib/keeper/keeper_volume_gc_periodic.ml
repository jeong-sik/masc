let ( let* ) = Result.bind

type outcome =
  | Reported of Keeper_volume_gc_answer.t
  | Skipped of string
  | Failed of string

type t =
  { observed_at : float
  ; outcome : outcome
  }

let envelope_field = "sandbox_volume_gc_report"

let steps ~ready ~resolve_claims_image ~judge =
  match ready () with
  | Error reason -> Skipped reason
  | Ok ready ->
    (match resolve_claims_image () with
     | Error reason -> Failed reason
     | Ok claims_image ->
       (match judge ready ~claims_image ~request:Keeper_volume_gc.Report_only with
        | Error reason -> Failed reason
        | Ok report ->
          Reported
            (Keeper_volume_gc_answer.of_report
               ~executed:false
               ~image_given:(Option.is_some claims_image)
               report)))
;;

let observe ~now ~ready ~resolve_claims_image ~judge =
  let outcome =
    match steps ~ready ~resolve_claims_image ~judge with
    | outcome -> outcome
    | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
    | exception exn -> Failed (Printexc.to_string exn)
  in
  { observed_at = now (); outcome }
;;

let reported_name = "reported"
let skipped_name = "skipped"
let failed_name = "failed"
let observed_at_field = "observed_at"
let outcome_field = "outcome"
let answer_field = "answer"
let reason_field = "reason"

let to_json t =
  let outcome =
    match t.outcome with
    | Reported answer ->
      [ outcome_field, `String reported_name
      ; answer_field, Keeper_volume_gc_answer.to_json answer
      ]
    | Skipped reason -> [ outcome_field, `String skipped_name; reason_field, `String reason ]
    | Failed reason -> [ outcome_field, `String failed_name; reason_field, `String reason ]
  in
  `Assoc ((observed_at_field, `Float t.observed_at) :: outcome)
;;

let surface = envelope_field

let reported_of_json fields =
  let* () =
    Json_util.reject_unknown_fields
      ~surface
      ~allowed:[ observed_at_field; outcome_field; answer_field ]
      fields
  in
  let* answer_json =
    match List.assoc_opt answer_field fields with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "%s.%s is required" surface answer_field)
  in
  let* answer = Keeper_volume_gc_answer.of_json answer_json in
  if answer.Keeper_volume_gc_answer.executed
  then Error (surface ^ ".answer executed, and a periodic pass only reports")
  else Ok (Reported answer)
;;

let reason_of_json make fields =
  let* () =
    Json_util.reject_unknown_fields
      ~surface
      ~allowed:[ observed_at_field; outcome_field; reason_field ]
      fields
  in
  let* reason = Json_util.require_field_string ~surface reason_field fields in
  Ok (make reason)
;;

let of_json = function
  | `Assoc fields ->
    let* observed_at = Json_util.require_field_float ~surface observed_at_field fields in
    let* name = Json_util.require_field_string ~surface outcome_field fields in
    let* outcome =
      if String.equal name reported_name
      then reported_of_json fields
      else if String.equal name skipped_name
      then reason_of_json (fun reason -> Skipped reason) fields
      else if String.equal name failed_name
      then reason_of_json (fun reason -> Failed reason) fields
      else Error (Printf.sprintf "%s.%s %S is not an outcome" surface outcome_field name)
    in
    Ok { observed_at; outcome }
  | _ -> Error (surface ^ " must be an object")
;;
