type serialized_request =
  { output_token_receipt : Types.output_token_receipt
  ; body_bytes : int
  ; body_sha256 : string
  }

type request_provenance =
  | Not_serialized
  | Serialized of serialized_request
  | External_unobserved
  | Interrupted_unobserved

type 'a t =
  { result : 'a
  ; request_provenance : request_provenance
  }

let before_serialization result = { result; request_provenance = Not_serialized }

let after_serialization ~(request : Complete_common.serialized_http_request) result =
  let serialized =
    { output_token_receipt = request.output_token_receipt
    ; body_bytes = String.length request.body
    ; body_sha256 = Digestif.SHA256.(digest_string request.body |> to_hex)
    }
  in
  { result; request_provenance = Serialized serialized }
;;

let map_result transform outcome =
  { outcome with result = transform outcome.result }
;;

let external_unobserved result =
  { result; request_provenance = External_unobserved }
;;

let interrupted_unobserved result =
  { result; request_provenance = Interrupted_unobserved }
;;
