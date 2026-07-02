(** Masc_context_injector — OAS context_injector for MASC agents.

    @since context_injector integration *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type config = {
  start_time : float;
}

let default_config () : config =
  { start_time = Time_compat.now () }

let iso8601_of_float ts = Masc_domain.iso8601_of_unix_seconds ts

(* ================================================================ *)
(* Context keys                                                      *)
(* ================================================================ *)

let key_wall_time = "session:wall_time"
let key_session_start = "session:session_start"
let key_elapsed_seconds = "session:elapsed_seconds"
let key_tool_call_count = "session:tool_call_count"
let key_last_tool_name = "session:last_tool_name"
let key_last_tool_outcome = "session:last_tool_outcome"
let key_tool_success_count = "session:tool_success_count"
let key_tool_error_count = "session:tool_error_count"

(* ================================================================ *)
(* ISO 8601 formatting                                               *)
(* ================================================================ *)

(* ================================================================ *)
(* Injector factory                                                  *)
(* ================================================================ *)

let make ~(config : config) () : Agent_sdk.Hooks.context_injector =
  let call_count = Atomic.make 0 in
  let success_count = Atomic.make 0 in
  let error_count = Atomic.make 0 in
  fun ~tool_name ~input:_ ~output ->
    let now = Time_compat.now () in
    let is_ok = match output with Ok _ -> true | Error _ -> false in
    let _ = Atomic.fetch_and_add call_count 1 in
    if is_ok then ignore (Atomic.fetch_and_add success_count 1)
    else ignore (Atomic.fetch_and_add error_count 1);
    let outcome_str = if is_ok then "ok" else "error" in
    let elapsed = now -. config.start_time in
    Some Agent_sdk.Hooks.{
      context_updates = [
        (key_wall_time, `String (Masc_domain.iso8601_of_unix_seconds now));
        (* Session anchor: lets [render_temporal_summary] recompute a
           fresh elapsed at turn start instead of freezing it at the
           last tool call. Constant across a session (= injector start). *)
        (key_session_start, `Float config.start_time);
        (key_elapsed_seconds, `Float elapsed);
        (key_tool_call_count, `Int (Atomic.get call_count));
        (key_last_tool_name, `String tool_name);
        (key_last_tool_outcome, `String outcome_str);
        (key_tool_success_count, `Int (Atomic.get success_count));
        (key_tool_error_count, `Int (Atomic.get error_count));
      ];
      extra_messages = [];
    }

(* ================================================================ *)
(* Temporal summary renderer                                         *)
(* ================================================================ *)

let get_string ctx key =
  match Agent_sdk.Context.get ctx key with
  | Some (`String s) -> Some s
  | _ -> None

let get_float ctx key =
  match Agent_sdk.Context.get ctx key with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let get_int ctx key =
  match Agent_sdk.Context.get ctx key with
  | Some (`Int i) -> Some i
  | _ -> None

let render_temporal_summary ?now (ctx : Agent_sdk.Context.t) : string option =
  (* [key_wall_time] presence is the "at least one tool has executed"
     sentinel (turn 0 renders no block). We do NOT display its stored
     value: it is the last tool-call timestamp and goes stale across
     idle turns, which is exactly the bug this renderer must avoid. *)
  match Agent_sdk.Context.get ctx key_wall_time with
  | None -> None
  | Some _ ->
    let now = match now with Some n -> n | None -> Time_compat.now () in
    (* [time=] is recomputed at render (= turn start), so a keeper waking
       after an idle gap sees the current wall clock, not a past tool time. *)
    let wall_time = iso8601_of_float now in
    let elapsed =
      match get_float ctx key_session_start with
      | Some session_start -> now -. session_start
      | None ->
        (* Backward compat: contexts written before [key_session_start]
           existed fall back to the stored (possibly stale) elapsed. *)
        get_float ctx key_elapsed_seconds |> Option.value ~default:0.0
    in
    let tool_count =
      get_int ctx key_tool_call_count |> Option.value ~default:0 in
    let last_tool =
      get_string ctx key_last_tool_name |> Option.value ~default:"none" in
    let outcome =
      get_string ctx key_last_tool_outcome |> Option.value ~default:"unknown" in
    Some (Printf.sprintf
      "[Temporal] time=%s elapsed=%.0fs tools=%d last=%s(%s)"
      wall_time elapsed tool_count last_tool outcome)
