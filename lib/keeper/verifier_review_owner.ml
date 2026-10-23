(** Durable owner of one verifier review original. *)

module V = Verifier_review_original
module Owner = Lane_addon_tool_request_owner

let ( let* ) = Result.bind

type store = Lane_addon_store.t

let scope = "verifier-reviews"
let tool_name = "verifier_review"

let attempt_request_id ~verification_id ~attempt =
  if attempt < 0
  then Error "verifier review attempt must be a non-negative integer"
  else Ok (Printf.sprintf "%s:attempt-%d" verification_id attempt)

(* The owner record requires a summary. It must be a short canonical digest of
   the fixed subject and lookup grants, never a mutable pointer to current
   state, so the stored record names the same original the caller prepared.
   The digest is canonical, so equal originals have equal summaries. *)
let summary_of (original : V.t) : (Yojson.Safe.t, string) result =
  let* digest = V.digest original in
  Ok
    (`Assoc
      [ "schema", `String V.schema
      ; "verification_id", `String (V.verification_id original)
      ; "attempt", `Int (V.attempt original)
      ; "original_digest", `String digest
      ])

type retain_error =
  | Original_invalid of string
  | Identity_mismatch of string
  | Retain_store_unavailable of string
  | Already_retained of string

(* [load_error] deliberately names its store failure differently from
   [retain_error]'s [Retain_store_unavailable]: the two error types are not a
   recursion group, and sharing a constructor name here made the type-checker
   merge them, hiding [Already_retained] from [retain]'s mapping. *)
type load_error =
  | Load_store_unavailable of string
  | Not_found
  | Corrupt_original of string

let map_retain_error ~request_id (err : Owner.error) : retain_error =
  match err with
  | Owner.Binding_conflict -> Already_retained request_id
  | Owner.Store_unavailable detail -> Retain_store_unavailable detail
  | Owner.Invalid_identity detail -> Identity_mismatch detail
  | Owner.Invalid_request detail -> Original_invalid detail

let retain ~store ~verification_id ~attempt ~installation_id ~package_id original =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Identity_mismatch detail)
  in
  (* The original's internal identity must match the key it is stored under,
     so a value prepared for one verification cannot be applied to a different
     attempt's slot. *)
  let* () =
    if String.equal (V.verification_id original) verification_id
       && V.attempt original = attempt
    then Ok ()
    else
      Error
        (Identity_mismatch
           (Printf.sprintf
              "original identity %s:%d does not match key %s:%d"
              (V.verification_id original)
              (V.attempt original)
              verification_id
              attempt))
  in
  let* request_json =
    (match V.to_json original with
     | json -> Ok json
     | exception exn -> Error (Printexc.to_string exn))
    |> Result.map_error (fun detail -> Original_invalid detail)
  in
  let* summary =
    summary_of original |> Result.map_error (fun detail -> Original_invalid detail)
  in
  (* Delegate the keep-exactly-one guarantee to [Owner.retain]: it compares the
     whole record (scope, request_id, installation, package, tool, digest,
     summary and body) and is idempotent only when every destination field
     matches, so a retain aimed at a different installation, package or tool
     is a [Binding_conflict], never an overwrite. We add nothing on top. *)
  Owner.retain
    ~store
    ~scope
    ~request_id
    ~installation_id
    ~package_id
    ~tool:tool_name
    ~summary
    ~request:request_json
  |> Result.map_error (map_retain_error ~request_id)

let load ~store ~verification_id ~attempt =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Load_store_unavailable detail)
  in
  let* existing =
    Owner.load ~store ~scope ~request_id
    |> Result.map_error (function
      | Owner.Store_unavailable detail -> Load_store_unavailable detail
      | Owner.Binding_conflict -> Load_store_unavailable "verifier review owner binding conflict"
      | Owner.Invalid_identity detail -> Load_store_unavailable detail
      | Owner.Invalid_request detail -> Load_store_unavailable detail)
  in
  match existing with
  | None -> Error Not_found
  | Some record ->
    (match V.of_json record.Owner.request with
     | Ok original ->
       if String.equal (V.verification_id original) verification_id
          && V.attempt original = attempt
       then Ok original
       else
         Error
           (Corrupt_original
              (Printf.sprintf
                 "stored original identity %s:%d does not match key %s:%d"
                 (V.verification_id original)
                 (V.attempt original)
                 verification_id
                 attempt))
     | Error detail -> Error (Corrupt_original detail))
