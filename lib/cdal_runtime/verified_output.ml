(** Phantom-typed verified output.

    The phantom type parameter ['status] is erased at runtime.
    [unverified output] and [verified output] have identical
    runtime representation — the difference is purely in the
    type system.

    @since 0.76.0 *)

type unverified
type verified

type verification_result =
  | Verified of
      { verifier : string
      ; confidence : float
      ; evidence : string
      }
  | Disputed of
      { verifier : string
      ; reason : string
      }
  | Abstained of
      { verifier : string
      ; reason : string
      }

(* The actual record — 'status is phantom (not stored anywhere) *)
type _ output =
  { response : Types.api_response
  ; producer : string
  ; verifications : verification_result list
  ; verified_flag : bool
  }

let of_response ~producer response =
  { response; producer; verifications = []; verified_flag = false }
;;

let verify (out : unverified output) ~verifier ~confidence ~evidence =
  if confidence >= 0.5
  then (
    let result = Verified { verifier; confidence; evidence } in
    Some
      { response = out.response
      ; producer = out.producer
      ; verifications = result :: out.verifications
      ; verified_flag = true
      })
  else None
;;

let verify_with_results (out : unverified output) results ?(min_confidence = 0.5) () =
  let has_verified =
    List.exists
      (function
        | Verified { confidence; _ } -> confidence >= min_confidence
        | Disputed _ | Abstained _ -> false)
      results
  in
  if has_verified
  then
    Some
      { response = out.response
      ; producer = out.producer
      ; verifications = results @ out.verifications
      ; verified_flag = true
      }
  else None
;;

let trust (out : unverified output) ~reason =
  let result = Verified { verifier = "trusted"; confidence = 1.0; evidence = reason } in
  { response = out.response
  ; producer = out.producer
  ; verifications = result :: out.verifications
  ; verified_flag = true
  }
;;

let content (out : verified output) = out.response

let text (out : verified output) =
  out.response.content
  |> List.filter_map (function
    | Types.Text s -> Some s
    | _ -> None)
  |> String.concat "\n"
;;

let producer (type s) (out : s output) = out.producer
let verifications (type s) (out : s output) = out.verifications
let is_verified (type s) (out : s output) = out.verified_flag

let raw_json (type s) (out : s output) =
  let text_content =
    out.response.content
    |> List.filter_map (function
      | Types.Text s -> Some s
      | _ -> None)
    |> String.concat "\n"
  in
  `Assoc
    [ "id", `String out.response.id
    ; "model", `String out.response.model
    ; "producer", `String out.producer
    ; "text", `String text_content
    ]
;;
