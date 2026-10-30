type serialized_request =
  { output_token_receipt : Types.output_token_receipt
  ; body_bytes : int
  ; body_sha256 : string
  }

type request_provenance =
  | Not_serialized
  | Serialized of serialized_request
  | Cache_reused of serialized_request
  | External_unobserved
  | Interrupted_unobserved

type 'a t =
  { result : 'a
  ; request_provenance : request_provenance
  }

let before_serialization result = { result; request_provenance = Not_serialized }

let seal_request (request : Complete_common.serialized_http_request) =
  { output_token_receipt = request.output_token_receipt
  ; body_bytes = String.length request.body
  ; body_sha256 = Agent_core_sha256.(digest_string request.body |> to_hex)
  }
;;

let after_serialization ~request result =
  { result; request_provenance = Serialized (seal_request request) }
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

let cache_reused ~request result =
  { result; request_provenance = Cache_reused (seal_request request) }
;;

let request_provenance_to_yojson provenance =
  let state, request = match provenance with
    | Not_serialized -> "not_serialized", None
    | Serialized request -> "serialized", Some request
    | Cache_reused request -> "cache_reused", Some request
    | External_unobserved -> "external_unobserved", None
    | Interrupted_unobserved -> "interrupted_unobserved", None
  in
  let request = match request with
    | None -> `Null
    | Some request ->
      `Assoc [ "output_token_receipt", Types.output_token_receipt_to_yojson request.output_token_receipt
             ; "body_bytes", `Int request.body_bytes
             ; "body_sha256", `String request.body_sha256 ]
  in
  `Assoc [ "state", `String state; "request", request ]
;;

let request_provenance_of_yojson json =
  let open Result.Syntax in
  let fields ~keys = function
    | `Assoc fields when
        List.sort String.compare (List.map fst fields) = List.sort String.compare keys ->
      Ok fields
    | _ -> Error "request provenance: missing, duplicate or unknown fields"
  in
  let decode_request json =
    let* fs = fields ~keys:["output_token_receipt"; "body_bytes"; "body_sha256"] json in
    let receipt_json = List.assoc "output_token_receipt" fs in
    let* output_token_receipt = Types.output_token_receipt_of_yojson receipt_json in
    let canonical = Types.output_token_receipt_to_yojson output_token_receipt in
    let sorted = function `Assoc fs -> `Assoc (List.sort compare fs) | value -> value in
    let* () = if Yojson.Safe.equal (sorted receipt_json) (sorted canonical)
      then Ok () else Error "request provenance: non-canonical output-token receipt" in
    match List.assoc "body_bytes" fs, List.assoc "body_sha256" fs with
    | `Int body_bytes, `String body_sha256 when body_bytes > 0 ->
      (match Agent_core_sha256.consistent_of_hex_opt body_sha256 with
       | Some digest when String.equal body_sha256 (Agent_core_sha256.to_hex digest) ->
         Ok {output_token_receipt; body_bytes; body_sha256}
       | Some _ | None -> Error "request provenance: invalid canonical SHA256")
    | _ -> Error "request provenance: expected positive body bytes and SHA256"
  in
  let* fs = fields ~keys:["state"; "request"] json in
  match List.assoc "state" fs, List.assoc "request" fs with
  | `String "not_serialized", `Null -> Ok Not_serialized
  | `String "external_unobserved", `Null -> Ok External_unobserved
  | `String "interrupted_unobserved", `Null -> Ok Interrupted_unobserved
  | `String "serialized", request -> Result.map (fun r -> Serialized r) (decode_request request)
  | `String "cache_reused", request -> Result.map (fun r -> Cache_reused r) (decode_request request)
  | _ -> Error "request provenance: unknown state or contradictory request evidence"
;;

let equal_request_provenance left right =
  Yojson.Safe.equal (request_provenance_to_yojson left) (request_provenance_to_yojson right)
;;

let pp_request_provenance ppf value =
  Format.pp_print_string ppf (Yojson.Safe.to_string (request_provenance_to_yojson value))
;;
