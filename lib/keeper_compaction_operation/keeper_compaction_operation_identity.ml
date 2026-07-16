type id_error = Invalid_canonical_uuid

module Make_id () = struct
  type t = Uuidm.t

  (* NDT-OK: entropy creates identity only; no lifecycle decision uses it. *)
  let rng = Random.State.make_self_init ()
  let rng_mutex = Stdlib.Mutex.create ()
  let generate () =
    Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.v4_gen rng ())
  ;;

  let of_string value =
    match Uuidm.of_string value with
    | Some id when String.equal value (Uuidm.to_string id) -> Ok id
    | Some _ | None -> Error Invalid_canonical_uuid
  ;;

  let to_string id = Uuidm.to_string id
  let equal = Uuidm.equal
  let compare = Uuidm.compare
end

module Operation_id = Make_id ()
module Attempt_id = Make_id ()

module Cause = struct
  type t = string
  type error =
    | Empty
    | Noncanonical

  let of_string value =
    if value = ""
    then Error Empty
    else if String.equal value (String.trim value)
    then Ok value
    else Error Noncanonical
  ;;

  let to_string value = value
  let equal = String.equal
end
