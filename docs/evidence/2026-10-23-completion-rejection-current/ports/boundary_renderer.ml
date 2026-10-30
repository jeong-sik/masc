(* Explicit lock-diagnostic renderer port; actual Types_core is included by
   the harness before this fragment. No completion/task authority is replaced. *)
type boundary_error = Lock_unavailable of string
let masc_error_to_string = function Lock_unavailable detail -> detail
