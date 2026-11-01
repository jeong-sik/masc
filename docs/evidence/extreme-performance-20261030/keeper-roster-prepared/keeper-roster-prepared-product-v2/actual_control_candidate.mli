module Decode = Fixture_types.Decode
type liveness = Fixture_types.Control.liveness =
  | Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
type reading = Fixture_types.Control.reading =
  { name : string; paused : bool; liveness : liveness }
type roster_view =
  | Roster_unobserved
  | Roster_partial of
      { observed : Decode.keeper_runtime list
      ; total : int
      }
  | Roster_invalid of
      { observed : Decode.keeper_runtime list
      ; errors : (string * string) list
      ; complete : bool
      }
  | Roster_complete of Decode.keeper_runtime list

type roster
(** One immutable fetched roster: the original view and its prepared name lookup
    are constructed together. The lookup preserves the decoded runtime values.
    Freshness, workspace admission and replacement belong to the owning read;
    this value does not authorize a different request or workspace. *)

val unobserved_roster : roster
val roster_view : roster -> roster_view
(** Inspect the original observation without reconstructing or reordering it. *)

val roster_of_reading :
  errors:(string * string) list ->
  rows:Decode.keeper_runtime list ->
  truncated:bool ->
  total:int ->
  roster
(** Build the view and immutable lookup once from what the route answered.
    Complete only when the route said it was not clamped {i and} returned as
    many rows as it said exist. This preparation belongs in the existing
    response-decode executor path, which may run inline under its existing
    policy. First observed rows and first errors retain their
    meaning; errors take precedence over observed rows of the same name. *)

val liveness_of_roster : roster -> string -> liveness
type action = Fixture_types.Control.action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup
  | Delete

val runs : reading -> bool option
val available : reading -> action list
