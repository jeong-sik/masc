(** Shared closed verdict for Keeper grouping and drawing (RFC-0515 §2.4.2). *)
type t =
  | Failing of { resting : bool }
  | Paused
  | Recovered
  | Sound
  | Other

val recovery_slots : int
val of_runtime : now:float -> Masc.Tui_decode.keeper_runtime option -> t
(** Pause takes precedence over failing health. Otherwise a failed or rested
    slot in the last 24 half hours makes a non-failing Keeper recovered,
    including an offline Keeper. A missing pulse cannot establish
    a recovery. Unread/offline without recovery is
    [Other], while running/idle without recovery is [Sound]. *)
