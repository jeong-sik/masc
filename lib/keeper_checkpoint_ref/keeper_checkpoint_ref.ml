type t =
  { trace_id : Keeper_id.Trace_id.t
  ; turn_count : int
  ; sha256 : string
  }

type create_error =
  | Negative_turn_count of int
  | Invalid_sha256 of string

let validate_coordinates ~turn_count =
  if turn_count < 0
  then Error (Negative_turn_count turn_count)
  else Ok ()
;;

(* A 13-109 MB checkpoint hashed in one digestif call held every other domain
   at the next stop-the-world barrier. Agent_core_sha256 feeds bounded slices,
   so the hash answers those requests between slices (RFC-0474 L2). *)
let sha256_of_canonical_bytes bytes =
  Agent_core_sha256.(to_hex (digest_string bytes))
;;

let of_persisted ~trace_id ~turn_count ~sha256 =
  match validate_coordinates ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    (match Agent_core_sha256.consistent_of_hex_opt sha256 with
     | Some digest when String.equal sha256 (Agent_core_sha256.to_hex digest) ->
       Ok { trace_id; turn_count; sha256 }
     | Some _ | None -> Error (Invalid_sha256 sha256))
;;

let equal left right =
  Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.turn_count right.turn_count
  && String.equal left.sha256 right.sha256
;;
