open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_autoresearch_broadcast — SSE broadcast for autoresearch events. *)

let broadcast_cycle_result (state : Autoresearch.loop_state) (record : Autoresearch.cycle_record) =
  try Sse.broadcast (`Assoc [
    ("type", `String "autoresearch_cycle");
    ("loop_id", `String state.loop_id);
    ("cycle", `Int record.cycle);
    ("hypothesis", `String record.hypothesis);
    ("decision", `String (Autoresearch.decision_to_string record.decision));
    ("score_before", `Float record.score_before);
    ("score_after", `Float record.score_after);
    ("delta", `Float record.delta);
    ("baseline", `Float state.baseline);
    ("best_score", `Float state.best_score);
  ]) with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Autoresearch.warn "broadcast_cycle_result failed: %s" (Stdlib.Printexc.to_string exn)

let broadcast_loop_lifecycle event_type (state : Autoresearch.loop_state) =
  try Sse.broadcast (`Assoc [
    ("type", `String event_type);
    ("loop_id", `String state.loop_id);
    ("status", `String (Autoresearch.status_to_string state.status));
    ("current_cycle", `Int state.current_cycle);
    ("best_score", `Float state.best_score);
    ("target_file", `String state.target_file);
  ]) with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Autoresearch.warn "broadcast_loop_lifecycle failed: %s" (Stdlib.Printexc.to_string exn)
