module Exec = Exact_output_execution

type t =
  { fingerprint : string
  ; http_status : int
  ; response_header_evidence_fingerprint : string
  ; raw_response_body_sha256 : string
  ; response_id : string option
  ; response_model : string option
  }

type raw_response =
  { body : string
  ; body_sha256 : string
  }

let fingerprint trace = trace.fingerprint
let equal left right = String.equal left.fingerprint right.fingerprint

let rec record_once state trace =
  match Atomic.get state with
  | Some existing when equal existing trace -> ()
  | Some _ -> invalid_arg "Exact_output: provider trace changed after installation"
  | None ->
    if not (Atomic.compare_and_set state None (Some trace)) then record_once state trace
;;

let raw_response (evidence : Exec.raw_response_evidence) =
  { body = evidence.raw_body; body_sha256 = evidence.raw_body_sha256 }
;;

let of_evidence ?response receipt (evidence : Exec.raw_response_evidence) =
  let http_status =
    match Exec.receipt_http_status receipt with
    | Some status -> status
    | None -> invalid_arg "Exact_output: response evidence without HTTP status"
  in
  let response_id, response_model =
    match response with
    | None -> None, None
    | Some (response : Types.api_response) -> Some response.id, Some response.model
  in
  let response_header_evidence_fingerprint =
    Http_client.response_header_evidence_fingerprint evidence.response_header_evidence
  in
  let payload =
    `Assoc
      [ "version", `Int 1
      ; "http_status", `Int http_status
      ; ( "response_header_evidence_fingerprint"
        , `String response_header_evidence_fingerprint )
      ; "raw_response_body_sha256", `String evidence.raw_body_sha256
      ; ( "response_id"
        , match response_id with
          | None -> `Null
          | Some value -> `String value )
      ; ( "response_model"
        , match response_model with
          | None -> `Null
          | Some value -> `String value )
      ]
  in
  let fingerprint =
    payload
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  { fingerprint
  ; http_status
  ; response_header_evidence_fingerprint
  ; raw_response_body_sha256 = evidence.raw_body_sha256
  ; response_id
  ; response_model
  }
;;
