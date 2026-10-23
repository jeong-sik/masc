module Lease = Native_addon_lease
let ( let* ) = Result.bind
let protect work = try work () with
  | (Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _) as exn -> Error (Printexc.to_string exn)
let lease result = Result.map_error Lease.error_to_string result
type t = { name : string; claim_directory : string; context : Yojson.Safe.t }
let foreign t = Printf.sprintf "%s %s belongs to another browser allocation" t.name t.claim_directory
let settled ~name claim =
  let* status=lease (Lease.status claim) in
  match status with
  | Lease.Settled -> Ok ()
  | Awaiting_exec | Live _ | Cleanup_pending _ -> Error (name ^ " has not settled")
let original t = protect (fun () ->
  match Unix.lstat t.claim_directory with
  | _ ->
    let* preparation=lease (Lease.recover_preparation ~directory:t.claim_directory) in
    (match preparation with
     | Lease.Unpublished -> Ok None
     | Current claim ->
       let* known=lease (Lease.cleanup_context claim) in
       if known=Some t.context then Ok (Some claim) else Error (foreign t))
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None)
let check_retained t =
  match Unix.lstat t.claim_directory with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (code, _, _) -> Error (t.claim_directory ^ ": " ^ Unix.error_message code)
  | _ ->
    (match Lease.inspect ~directory:t.claim_directory with
     | Error (refused : Lease.inspection_error) -> Error refused.refusal
     | Ok None -> Ok ()
     | Ok (Some recorded) -> if recorded.context = Some t.context then Ok () else Error (foreign t))
let settle t =
  let* claim=original t in
  match claim with
  | None -> Ok ()
  | Some claim -> let* ()=lease (Lease.request_termination claim) in settled ~name:t.name claim
let check_settled t = protect (fun () ->
  match Unix.lstat t.claim_directory with
  | _ ->
    (match Lease.current ~directories:[t.claim_directory] with
     | Ok claim ->
       let* known=lease (Lease.cleanup_context claim) in
       if known=Some t.context then settled ~name:t.name claim else Error (foreign t)
     | Error error ->
       (* Only [settle]'s gate fences a reservation that was never published.
          The lease error does not say whether that is the cause, so the
          refusal names it as one possibility. *)
       Error (Printf.sprintf
         "%s %s is not one published claim (%s); if it is a reservation that was never published, the next cleanup pass fences it and the retain can then be repeated"
         t.name t.claim_directory (Lease.error_to_string error)))
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())
