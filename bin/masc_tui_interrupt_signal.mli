(** What a keeper turn interrupt request actually told us.

    The server answers whether the cancel signal was delivered, not whether the
    turn stopped. Whether the fiber then stops is a later event: a turn parked
    in an uncancellable section keeps running, and reading this as the outcome
    is what hid a 63-minute hang (masc #29229).

    This lives apart from the HTTP plumbing so the decode can be tested without
    linking the TUI executable. *)

type interrupt_signal =
  | Signalled of { turn_id : int option }
  | Not_signalled of
      { reason : string
      ; detail : string option
      }

val decode_interrupt_signal
  :  expected_request_id:string
  -> Yojson.Safe.t
  -> (interrupt_signal, string) result
(** Rejects a response whose echoed [request_id] is not the one asked about, so
    a late answer to an earlier interrupt is never read as this one's outcome. *)
