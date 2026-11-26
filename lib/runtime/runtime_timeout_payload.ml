type t =
  { seconds : float
  ; stage : string option
  ; turn_accepted : bool option
  }

let of_seconds seconds = { seconds; stage = None; turn_accepted = None }
let of_codex ~seconds ~turn_accepted = { seconds; stage = None; turn_accepted = Some turn_accepted }
let of_acp ~stage ~timeout_s = { seconds = timeout_s; stage = Some stage; turn_accepted = None }
