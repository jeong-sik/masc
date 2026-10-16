module Lifecycle = Lane_addon_lifecycle

type port = {
  read_engine : unit -> (Lifecycle.engine, Lifecycle.engine_fault) result;
}

let ( let* ) = Result.bind

let fault_failure ~recorded = function
  | Lifecycle.Unreachable detail -> Lifecycle.Engine_unreachable detail
  | Lifecycle.Identity_unreadable detail ->
      Lifecycle.Engine_mismatch { recorded; observed = Lifecycle.Unreadable_engine detail }

let reaches port ~expected = match port.read_engine () with
  | Ok engine when Lifecycle.engine_equal engine expected -> Ok ()
  | Ok engine ->
      Error (Lifecycle.Engine_mismatch { recorded = expected; observed = Lifecycle.Other_engine engine })
  | Error fault -> Error (fault_failure ~recorded:expected fault)

let proven port ~expected ~lift work =
  let* () = reaches port ~expected |> Result.map_error lift in
  let* value = work () in
  let* () = reaches port ~expected |> Result.map_error lift in
  Ok value
