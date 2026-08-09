type t =
  { root : string
  ; base_path : string
  }

let ref_prefix = "sha256:"

let validate_ref value =
  let prefix_length = String.length ref_prefix in
  let expected_length = prefix_length + 64 in
  if String.length value <> expected_length
  then Error (Printf.sprintf "blob ref must be exactly %d bytes" expected_length)
  else if not (String.equal (String.sub value 0 prefix_length) ref_prefix)
  then Error "blob ref must begin with sha256:"
  else
    let rec loop index =
      if index = expected_length
      then Ok value
      else
        match String.unsafe_get value index with
        | '0' .. '9' | 'a' .. 'f' -> loop (index + 1)
        | found ->
          Error
            (Printf.sprintf
               "blob ref has non-lowercase-hex byte %C at index %d"
               found
               index)
    in
    loop prefix_length
;;

module Input_ref = struct
  type t = string
  let of_string = validate_ref
  let to_string value = value
  let equal = String.equal
end

module Outcome_ref = struct
  type t = string
  let of_string = validate_ref
  let to_string value = value
  let equal = String.equal
end

module State_ref = struct
  type t = string
  let of_string = validate_ref
  let to_string value = value
  let equal = String.equal
end

module Delivery_payload_ref = struct
  type t = string
  let of_string = validate_ref
  let to_string value = value
  let equal = String.equal
end

module Delivery_evidence_ref = struct
  type t = string
  let of_string = validate_ref
  let to_string value = value
  let equal = String.equal
end

type error =
  | Invalid_ref of string
  | Filesystem_error of string
  | Read_error of string
  | Integrity_error of string
  | Kind_mismatch of
      { expected : string
      ; actual : string
      }

let error_to_string = function
  | Invalid_ref detail -> "invalid operation blob ref: " ^ detail
  | Filesystem_error detail -> "operation blob write failed: " ^ detail
  | Read_error detail -> "operation blob read failed: " ^ detail
  | Integrity_error detail -> "operation blob integrity failure: " ^ detail
  | Kind_mismatch { expected; actual } ->
    Printf.sprintf
      "operation blob kind mismatch: expected=%s actual=%s"
      expected
      actual
;;

let create ~base_path ~keeper_runtime_dir =
  { root = Filename.concat keeper_runtime_dir "operation-blobs/sha256"
  ; base_path
  }
;;

let root_dir t = t.root

let digest_of_ref value =
  String.sub value (String.length ref_prefix) 64
;;

let path_of_ref t value =
  let digest = digest_of_ref value in
  Filename.concat (Filename.concat t.root (String.sub digest 0 2)) digest
;;

let canonical_envelope ~kind payload =
  Keeper_operation_request.Canonical_json.of_yojson
    (`Assoc
       [ "schema", `String "masc.keeper_operation.blob.v1"
       ; "kind", `String kind
       ; ( "payload"
         , Keeper_operation_request.Canonical_json.to_yojson payload )
       ])
  |> Result.map_error Keeper_operation_request.Canonical_json.error_to_string
;;

let owned_read_error_to_string error =
  Fs_compat.owned_regular_file_read_error_to_string error
;;

let read_exact t path =
  match Fs_compat.load_owned_regular_file ~ownership_root:t.base_path path with
  | Error error -> Error (Read_error (owned_read_error_to_string error))
  | Ok value -> Ok value
;;

let ensure_shard t path =
  let shard = Filename.dirname path in
  try
    Fs_compat.mkdir_p shard;
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:t.base_path shard with
    | Ok (Fs_compat.Owned_directory _) -> Ok ()
    | Ok Fs_compat.Owned_directory_missing ->
      Error (Filesystem_error ("blob shard was not created: " ^ shard))
    | Error rejection ->
      Error
        (Filesystem_error
           (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  with
  | Sys_error detail -> Error (Filesystem_error detail)
  | Unix.Unix_error (code, operation, argument) ->
    Error
      (Filesystem_error
         (Printf.sprintf
            "%s(%s): %s"
            operation
            argument
            (Unix.error_message code)))
;;

let put_common t ~kind payload =
  match canonical_envelope ~kind payload with
  | Error detail -> Error (Integrity_error detail)
  | Ok envelope ->
    let bytes = Keeper_operation_request.Canonical_json.to_bytes envelope in
    let digest = Digestif.SHA256.(digest_string bytes |> to_hex) in
    let reference = ref_prefix ^ digest in
    let path = path_of_ref t reference in
    (match ensure_shard t path with
     | Error _ as error -> error
     | Ok () ->
       (match Fs_compat.save_file_atomic_strict path bytes with
        | Error detail -> Error (Filesystem_error detail)
        | Ok () ->
          (match read_exact t path with
           | Error _ as error -> error
           | Ok None ->
             Error
               (Integrity_error
                  "durably published blob disappeared before read-back")
           | Ok (Some observed) ->
             let observed_digest =
               Digestif.SHA256.(digest_string observed |> to_hex)
             in
             if not (String.equal bytes observed)
             then Error (Integrity_error "blob read-back bytes differ")
             else if not (String.equal digest observed_digest)
             then
               Error
                 (Integrity_error
                    (Printf.sprintf
                       "blob digest mismatch expected=%s actual=%s"
                       digest
                       observed_digest))
             else Ok reference)))
;;

let exact_assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Integrity_error (Printf.sprintf "blob is missing field %S" name))
;;

let decode_envelope ~expected_kind bytes =
  match Keeper_operation_request.Canonical_json.of_string bytes with
  | Error error ->
    Error
      (Integrity_error
         (Keeper_operation_request.Canonical_json.error_to_string error))
  | Ok canonical ->
    if
      not
        (String.equal
           bytes
           (Keeper_operation_request.Canonical_json.to_bytes canonical))
    then Error (Integrity_error "blob bytes are not canonical JSON")
    else
      match Keeper_operation_request.Canonical_json.to_yojson canonical with
      | `Assoc fields when List.length fields = 3 ->
        (match exact_assoc_field "schema" fields with
         | Error _ as error -> error
         | Ok (`String "masc.keeper_operation.blob.v1") ->
           (match exact_assoc_field "kind" fields with
            | Error _ as error -> error
            | Ok (`String actual_kind) when String.equal actual_kind expected_kind ->
              (match exact_assoc_field "payload" fields with
               | Error _ as error -> error
               | Ok payload ->
                 Keeper_operation_request.Canonical_json.of_yojson payload
                 |> Result.map_error (fun error ->
                   Integrity_error
                     (Keeper_operation_request.Canonical_json.error_to_string error)))
            | Ok (`String actual) ->
              Error (Kind_mismatch { expected = expected_kind; actual })
            | Ok _ -> Error (Integrity_error "blob kind must be a string"))
         | Ok (`String actual) ->
           Error (Integrity_error ("unsupported blob schema: " ^ actual))
         | Ok _ -> Error (Integrity_error "blob schema must be a string"))
      | `Assoc _ -> Error (Integrity_error "blob must contain exactly three fields")
      | _ -> Error (Integrity_error "blob envelope must be an object")
;;

let fetch_common t ~kind reference =
  match validate_ref reference with
  | Error detail -> Error (Invalid_ref detail)
  | Ok reference ->
    let expected_digest = digest_of_ref reference in
    let path = path_of_ref t reference in
    (match read_exact t path with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some bytes) ->
       let actual_digest = Digestif.SHA256.(digest_string bytes |> to_hex) in
       if not (String.equal expected_digest actual_digest)
       then
         Error
           (Integrity_error
              (Printf.sprintf
                 "blob digest mismatch expected=%s actual=%s"
                 expected_digest
                 actual_digest))
       else decode_envelope ~expected_kind:kind bytes |> Result.map Option.some)
;;

let put_input t payload = put_common t ~kind:"input" payload
let put_outcome t payload = put_common t ~kind:"outcome" payload
let put_state t payload = put_common t ~kind:"state" payload
let put_delivery_payload t payload = put_common t ~kind:"delivery_payload" payload
let put_delivery_evidence t payload = put_common t ~kind:"delivery_evidence" payload

let fetch_input t reference =
  fetch_common t ~kind:"input" (Input_ref.to_string reference)
;;

let fetch_outcome t reference =
  fetch_common t ~kind:"outcome" (Outcome_ref.to_string reference)
;;

let fetch_state t reference =
  fetch_common t ~kind:"state" (State_ref.to_string reference)
;;

let fetch_delivery_payload t reference =
  fetch_common t ~kind:"delivery_payload" (Delivery_payload_ref.to_string reference)
;;

let fetch_delivery_evidence t reference =
  fetch_common
    t
    ~kind:"delivery_evidence"
    (Delivery_evidence_ref.to_string reference)
;;
