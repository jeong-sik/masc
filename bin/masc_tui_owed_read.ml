type t =
  | Settled
  | Owed of { failures : int }
  | Reading of { failures : int; changed_since : bool }
  | Waiting of { failures : int; retry_at : float }

let settled = Settled

let changed = function
  | Settled -> Owed { failures = 0 }
  | Owed _ as owed -> owed
  | Reading reading -> Reading { reading with changed_since = true }
  (* A change during a failure wait stays on the wait: the scheduled retry
     reads the changed state, and the failures that grew the wait are kept. *)
  | Waiting _ as waiting -> waiting

let started = function
  | Settled -> Reading { failures = 0; changed_since = false }
  | Owed { failures } | Waiting { failures; _ } ->
      Reading { failures; changed_since = false }
  | Reading { failures; _ } -> Reading { failures; changed_since = false }

let succeeded = function
  | Reading { changed_since = true; _ } -> Owed { failures = 0 }
  | Reading { changed_since = false; _ } -> Settled
  | (Settled | Owed _ | Waiting _) as unchanged -> unchanged

let failed ~retry_s ~max_retry_s ~now = function
  | Reading { failures; _ } ->
      let failures = failures + 1 in
      let wait = Float.min max_retry_s (retry_s *. Float.pow 2.0 (float_of_int (failures - 1))) in
      Waiting { failures; retry_at = now +. wait }
  | (Settled | Owed _ | Waiting _) as unchanged -> unchanged

let abandoned = function
  | Reading { failures; _ } -> Owed { failures }
  | (Settled | Owed _ | Waiting _) as unchanged -> unchanged

let due ~now = function
  | Owed _ -> true
  | Waiting { retry_at; _ } -> now >= retry_at
  | Settled | Reading _ -> false

let stale_at_to_schedule ~now = function
  | Some at when at > now -> Some at
  | Some _ | None -> None
