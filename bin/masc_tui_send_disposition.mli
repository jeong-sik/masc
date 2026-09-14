(** Both dispositions submit immediately. Updates asks the server to apply
    the input to the observed conversation using atomic interactive admission. *)
type 'request t =
  | Sends
  | Updates of 'request

val of_state : inflight:'request option -> waiting:'request option -> 'request t
