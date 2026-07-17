type t =
  { trace_id : Keeper_id.Trace_id.t
  ; generation : int
  ; turn_count : int
  ; sha256 : string
  }

type create_error =
  | Negative_generation of int
  | Negative_turn_count of int
  | Invalid_sha256 of string

let validate_coordinates ~generation ~turn_count =
  if generation < 0
  then Error (Negative_generation generation)
  else if turn_count < 0
  then Error (Negative_turn_count turn_count)
  else Ok ()
;;

let create ~trace_id ~generation ~turn_count ~canonical_checkpoint_bytes =
  match validate_coordinates ~generation ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    Ok
      { trace_id
      ; generation
      ; turn_count
      ; sha256 = Digestif.SHA256.(digest_string canonical_checkpoint_bytes |> to_hex)
      }
;;

let of_persisted ~trace_id ~generation ~turn_count ~sha256 =
  match validate_coordinates ~generation ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    (match Digestif.SHA256.consistent_of_hex_opt sha256 with
     | Some digest when String.equal sha256 (Digestif.SHA256.to_hex digest) ->
       Ok { trace_id; generation; turn_count; sha256 }
     | Some _ | None -> Error (Invalid_sha256 sha256))
;;

let equal left right =
  Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.generation right.generation
  && Int.equal left.turn_count right.turn_count
  && String.equal left.sha256 right.sha256
;;
