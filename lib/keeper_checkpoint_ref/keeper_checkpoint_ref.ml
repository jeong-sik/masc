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

(* Digestif's string update hashes its whole argument in one [@@noalloc] C
   call, and an OCaml 5 domain answers a stop-the-world request only at a
   poll point. While one domain hashed a 13-109 MB checkpoint in a single
   call, every other domain that reached a minor collection's barrier, the
   scheduler domain included, waited for the hash to end. Feeding one slice
   per call returns to OCaml between slices. *)
let digest_slice_bytes = 1 lsl 20

let sha256_of_canonical_bytes bytes =
  let length = String.length bytes in
  let rec feed ctx off =
    if off >= length
    then ctx
    else (
      let len = Int.min digest_slice_bytes (length - off) in
      feed (Digestif.SHA256.feed_string ctx ~off ~len bytes) (off + len))
  in
  Digestif.SHA256.(to_hex (get (feed empty 0)))
;;

let create ~trace_id ~turn_count ~canonical_checkpoint_bytes =
  match validate_coordinates ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    Ok
      { trace_id
      ; turn_count
      ; sha256 = sha256_of_canonical_bytes canonical_checkpoint_bytes
      }
;;

let of_persisted ~trace_id ~turn_count ~sha256 =
  match validate_coordinates ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    (match Digestif.SHA256.consistent_of_hex_opt sha256 with
     | Some digest when String.equal sha256 (Digestif.SHA256.to_hex digest) ->
       Ok { trace_id; turn_count; sha256 }
     | Some _ | None -> Error (Invalid_sha256 sha256))
;;

let equal left right =
  Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.turn_count right.turn_count
  && String.equal left.sha256 right.sha256
;;
