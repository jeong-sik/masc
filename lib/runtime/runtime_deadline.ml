type t = { expires_at_s : float }

let create ~expires_at_s = { expires_at_s }

let of_seconds_from_now ~clock secs =
  { expires_at_s = Eio.Time.now clock +. secs }

let expires_at d = d.expires_at_s

let remaining_at ~now_s d = Float.max 0.0 (d.expires_at_s -. now_s)

let composed_attempt_budget_at ~now_s ~deadline ~amplifier =
  Float.min amplifier (remaining_at ~now_s deadline)

let is_expired_at ~now_s d = remaining_at ~now_s d = 0.0

let remaining_seconds ~clock d = remaining_at ~now_s:(Eio.Time.now clock) d

let composed_attempt_budget ~clock ~deadline ~amplifier =
  composed_attempt_budget_at ~now_s:(Eio.Time.now clock) ~deadline ~amplifier

let is_expired ~clock d = is_expired_at ~now_s:(Eio.Time.now clock) d
