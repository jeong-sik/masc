(** See [token_count.mli] for the rationale (RFC-0149 §3.2). *)

type pre
type post
type 'phase t = int

let pre_estimate (n : int) : pre t = max 0 n
let post_recount (n : int) : post t = max 0 n

let to_int (n : _ t) : int = n

let saved ~(pre : pre t) ~(post : post t) :
    [ `Saved of int | `Divergent of int ] =
  if post <= pre then `Saved (pre - post)
  else `Divergent (post - pre)
