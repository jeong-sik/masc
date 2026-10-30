type source_kind =
  | Declaration
  | Probe
[@@deriving show, eq]

type confidence =
  | Low
  | Medium
  | High
[@@deriving show, eq]

type evidence =
  { source_kind : source_kind
  ; source_ref : string
  ; checked_at_unix_s : int
  ; confidence : confidence
  ; expires_at_unix_s : int option
  }
[@@deriving show, eq]

type observation =
  { accepted_through : int
  ; rejected_from : int option
  }
[@@deriving show, eq]

type t =
  { observation : observation
  ; evidence : evidence
  }
[@@deriving show, eq]

type validation_error =
  | Invalid_source_ref
  | Invalid_checked_at of int
  | Missing_probe_expiry
  | Invalid_expiry of
      { checked_at_unix_s : int
      ; expires_at_unix_s : int
      }
  | Invalid_accepted_through of int
  | Invalid_rejected_from of
      { accepted_through : int
      ; rejected_from : int
      }
[@@deriving show, eq]

let make
      ~source_kind
      ~source_ref
      ~checked_at_unix_s
      ~confidence
      ?expires_at_unix_s
      ~accepted_through
      ?rejected_from
      ()
  =
  if source_ref = "" || String.trim source_ref <> source_ref
  then Error Invalid_source_ref
  else if checked_at_unix_s < 0
  then Error (Invalid_checked_at checked_at_unix_s)
  else if accepted_through < 0
  then Error (Invalid_accepted_through accepted_through)
  else if source_kind = Probe && Option.is_none expires_at_unix_s
  then Error Missing_probe_expiry
  else (
    match expires_at_unix_s, rejected_from with
    | Some expires_at_unix_s, _ when expires_at_unix_s <= checked_at_unix_s ->
      Error (Invalid_expiry { checked_at_unix_s; expires_at_unix_s })
    | _, Some rejected_from when rejected_from <= accepted_through ->
      Error (Invalid_rejected_from { accepted_through; rejected_from })
    | _ ->
      Ok
        { observation = { accepted_through; rejected_from }
        ; evidence =
            { source_kind; source_ref; checked_at_unix_s; confidence; expires_at_unix_s }
        })
;;

type admission_error =
  | Evidence_not_yet_valid of
      { now_unix_s : int
      ; checked_at_unix_s : int
      }
  | Evidence_expired of
      { now_unix_s : int
      ; expires_at_unix_s : int
      }
  | Boundary_unknown of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }
  | Input_rejected of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int
      }
[@@deriving show, eq]

let check_evidence ~now_unix_s constraint_ =
  let evidence = constraint_.evidence in
  if now_unix_s < evidence.checked_at_unix_s
  then
    Error
      (Evidence_not_yet_valid
         { now_unix_s; checked_at_unix_s = evidence.checked_at_unix_s })
  else (
    match evidence.expires_at_unix_s with
    | Some expires_at_unix_s when now_unix_s >= expires_at_unix_s ->
      Error (Evidence_expired { now_unix_s; expires_at_unix_s })
    | Some _ | None -> Ok ())
;;

let admit ~now_unix_s ~input_tokens constraint_ =
  match check_evidence ~now_unix_s constraint_ with
  | Error error -> Error error
  | Ok () ->
    let observation = constraint_.observation in
    if input_tokens <= observation.accepted_through
    then Ok ()
    else (
      match observation.rejected_from with
      | Some rejected_from when input_tokens >= rejected_from ->
        Error
          (Input_rejected
             { input_tokens
             ; accepted_through = observation.accepted_through
             ; rejected_from
             })
      | rejected_from ->
        Error
          (Boundary_unknown
             { input_tokens
             ; accepted_through = observation.accepted_through
             ; rejected_from
             }))
;;

let source_kind_of_string = function
  | "declaration" -> Some Declaration
  | "probe" -> Some Probe
  | _ -> None
;;

let source_kind_to_string = function
  | Declaration -> "declaration"
  | Probe -> "probe"
;;

let confidence_of_string = function
  | "low" -> Some Low
  | "medium" -> Some Medium
  | "high" -> Some High
  | _ -> None
;;

let confidence_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
;;

let option_int = function
  | None -> "none"
  | Some value -> "some:" ^ string_of_int value
;;

let fingerprint_parts constraint_ =
  let evidence = constraint_.evidence in
  let observation = constraint_.observation in
  [ "source_kind=" ^ source_kind_to_string evidence.source_kind
  ; "source_ref=" ^ evidence.source_ref
  ; "checked_at_unix_s=" ^ string_of_int evidence.checked_at_unix_s
  ; "confidence=" ^ confidence_to_string evidence.confidence
  ; "expires_at_unix_s=" ^ option_int evidence.expires_at_unix_s
  ; "accepted_through=" ^ string_of_int observation.accepted_through
  ; "rejected_from=" ^ option_int observation.rejected_from
  ]
;;
