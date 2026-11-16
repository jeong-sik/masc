(* HIGH-RISK-UNREVIEWED: only [draw] makes a [t], so a [t] holds the hex
   digits of Random_id.hex and nothing that ends a source or an attribute. *)
type t = string

let random_bytes = 32
let draw () = Random_id.hex ~bytes:random_bytes
let source nonce = Printf.sprintf "'nonce-%s'" nonce
let attribute nonce = Printf.sprintf "nonce=\"%s\"" nonce
