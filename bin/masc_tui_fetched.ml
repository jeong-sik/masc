(* One fetched thing, and what is known about it right now.

   The panes model this as two independent options -- a snapshot and an
   error -- and two options cannot say "asked, still waiting": [None, None]
   means both "never asked" and "in flight". Measured 2026-09-05, that is why
   the TUI has 71 places that can report a failure and five that can report a
   fetch in progress. A pane before its first answer draws an empty list,
   which is what a pane with no rows draws.

   The states are a closed sum instead, so a renderer cannot leave one out.
   Lifted from [Masc_tui_board_detail], which had already worked this out for
   one pane; the key is a parameter now, and a pane with nothing to key on
   uses [unit].

   The value is immutable and every transition returns a new one. A pane
   holds it in the mutable cell it already has, and a later move to a fully
   immutable state record inherits this unchanged. *)

type 'k request =
  { key : 'k
  ; generation : int64
  }

type ('k, 'a) status =
  | Status_absent
  | Status_loading of 'k request
  | Status_ready of 'k request * 'a
  | Status_refreshing of 'k request * 'a
      (** A revalidation of what is already on screen: the request is in
          flight and ['a] is the last good value, which keeps rendering until
          the completion lands. Without this state every periodic refresh
          flips Ready back to Loading and the pane collapses to its
          placeholder for a frame. *)
  | Status_failed of 'k request * string

type ('k, 'a) t =
  { latest_generation : int64
  ; status : ('k, 'a) status
  }

type 'a view =
  | Absent  (** Never asked. *)
  | Loading  (** Asked, no answer yet, nothing to show meanwhile. *)
  | Ready of 'a
  | Failed of string

type ('k, 'a) start_result =
  | Already_loading
  | Started of ('k, 'a) t * 'k request

let initial = { latest_generation = 0L; status = Status_absent }
let request_key request = request.key

let same_request ~equal left right =
  equal left.key right.key && Int64.equal left.generation right.generation
;;

let is_current ~equal state request =
  match state.status with
  | Status_loading current -> same_request ~equal current request
  | Status_refreshing (current, _) -> same_request ~equal current request
  | Status_absent | Status_ready _ | Status_failed _ -> false
;;

let start ~equal state ~key =
  let fresh status =
    let generation = Int64.succ state.latest_generation in
    let request = { key; generation } in
    Started ({ latest_generation = generation; status = status request }, request)
  in
  match state.status with
  | Status_loading request when equal request.key key -> Already_loading
  | Status_refreshing (request, _) when equal request.key key -> Already_loading
  | Status_ready (current, value) when equal current.key key ->
    (* Revalidating what is already shown: keep the last good value on screen
       under a fresh generation. *)
    fresh (fun request -> Status_refreshing (request, value))
  | Status_absent
  | Status_loading _
  | Status_ready _
  | Status_refreshing _
  | Status_failed _ -> fresh (fun request -> Status_loading request)
;;

let clear state = { state with status = Status_absent }

let complete ~equal state request result =
  if not (is_current ~equal state request)
  then
    (* An answer for a request the pane has moved past. Dropping it is the
       point: showing it beside a different key reads as that key's value. *)
    state
  else (
    let status =
      match result with
      | Ok value -> Status_ready (request, value)
      | Error error -> Status_failed (request, error)
    in
    { state with status })
;;

let view_for ~equal state ~key =
  let matches request = equal request.key key in
  match state.status with
  | Status_loading request when matches request -> Loading
  | Status_ready (request, value) when matches request -> Ready value
  | Status_refreshing (request, value) when matches request ->
    (* The revalidation is in flight; the reader keeps the last good value
       until the completion swaps it. *)
    Ready value
  | Status_failed (request, error) when matches request -> Failed error
  | Status_absent
  | Status_loading _
  | Status_ready _
  | Status_refreshing _
  | Status_failed _ -> Absent
;;
