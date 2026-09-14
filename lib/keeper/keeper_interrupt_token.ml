type t = string

(* NDT-OK: randomness supplies stop identity only; it never selects work. *)
let rng = Random.State.make_self_init ()
let rng_mutex = Stdlib.Mutex.create ()

let fresh () =
  Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.to_string (Uuidm.v4_gen rng ()))
;;

let equal = String.equal
let to_string token = token

let of_string text =
  match Uuidm.of_string text with
  | Some uuid -> Ok (Uuidm.to_string uuid)
  | None -> Error "interrupt_token must be a UUID"
;;
