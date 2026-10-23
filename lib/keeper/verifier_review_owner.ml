(** Durable owner of one verifier review original. *)

module V = Verifier_review_original
module Owner = Lane_addon_tool_request_owner

let ( let* ) = Result.bind

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

let retain ~store ~verification_id ~attempt ~installation_id ~package_id original =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Identity_invalid detail)
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
  (* Reuse the durable owner's idempotence: retaining the identical original
     at the same key is a no-op; retaining a different one is a conflict we
     surface as Already_retained rather than overwrite. The caller chooses a
     fresh attempt key for a retry. *)
  let* existing = Owner.load ~store ~scope ~request_id in
  (match existing with
   | Some existing ->
     if Yojson.Safe.equal existing.Owner.request request_json
     then Ok ()
     else Error (Already_retained request_id)
   | None ->
     Owner.retain
       ~store
       ~scope
       ~request_id
       ~installation_id
       ~package_id
       ~tool:tool_name
       ~summary
       ~request:request_json
     |> Result.map_error (fun err ->
       match err with
       | Owner.Binding_conflict -> Already_retained request_id
       | Owner.Store_unavailable detail -> Store_unavailable detail
       | Owner.Invalid_identity detail -> Identity_invalid detail
       | Owner.Invalid_request detail -> Original_invalid detail))

type load_error =
  | Store_unavailable of string
  | Not_found
  | Corrupt_original of string

let load ~store ~verification_id ~attempt =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let* existing =
    Owner.load ~store ~scope ~request_id
    |> Result.map_error (fun err ->
      match err with
      | Owner.Store_unavailable detail -> Store_unavailable detail
      | _ -> Store_unavailable "verifier review owner record unavailable")
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
         Corrupt_original
           (Printf.sprintf
              "stored original identity %s:%d does not match key %s:%d"
              (V.verification_id original)
              (V.attempt original)
              verification_id
              attempt)
     | Error detail -> Corrupt_original detail)
