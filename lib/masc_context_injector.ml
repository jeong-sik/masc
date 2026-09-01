(** Masc_context_injector — AGENT_CORE context_injector for MASC agents.

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

let make ~(config : config) () : Agent_core.Hooks.context_injector =
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
    Some Agent_core.Hooks.{
      context_updates = [
        (key_wall_time, `String (Masc_domain.iso8601_of_unix_seconds now));
        (* Session anchor: lets [render_temporal_summary] recompute a
           fresh elapsed at turn start instead of freezing it at the
           last tool call. Constant across a session (= injector start). *)
        (key_session_start, `Float config.start_time);
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
  match Agent_core.Context.get ctx key with
  | Some (`String s) -> Some s
  | _ -> None

let get_float ctx key =
  match Agent_core.Context.get ctx key with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let get_int ctx key =
  match Agent_core.Context.get ctx key with
  | Some (`Int i) -> Some i
  | _ -> None

let tool_summary_fields ctx =
  match
    ( get_int ctx key_tool_call_count,
      get_string ctx key_last_tool_name,
      get_string ctx key_last_tool_outcome )
  with
  | Some tool_count, Some last_tool, Some outcome ->
    Some (tool_count, last_tool, outcome)
  | _ -> None

let render_temporal_summary ?now (ctx : Agent_core.Context.t) : string =
  (* The clock is unconditional: before this became total, a turn with no
     tool execution yet rendered no block at all, so the model had no idea
     what time it was and hand-typed prose timestamps drifted by whole
     hours (#32199). [key_wall_time] presence still means "at least one
     tool has executed" — it now gates only the corruption diagnostics
     below, never the clock. Its stored value is never displayed: it is
     the last tool-call timestamp and goes stale across idle turns. *)
  let tool_context_exists = Agent_core.Context.get ctx key_wall_time <> None in
  let now = match now with Some n -> n | None -> Time_compat.now () in
  (* [time=] is recomputed at render (= turn start), so a keeper waking
     after an idle gap sees the current wall clock, not a past tool time. *)
  let wall_time = iso8601_of_float now in
  let elapsed_part =
    match get_float ctx key_session_start with
    | Some session_start -> Printf.sprintf " elapsed=%.0fs" (now -. session_start)
    | None ->
      (* A retired-shape context (tools ran, no session anchor) is not
         repaired: elapsed is omitted rather than recomputed from any
         legacy key. A fresh context omits it silently. *)
      if tool_context_exists
      then Log.Keeper.warn "Temporal summary omits elapsed: missing %s" key_session_start;
      ""
  in
  let tools_part =
    match tool_summary_fields ctx with
    | Some (tool_count, last_tool, outcome) ->
      Printf.sprintf " tools=%d last=%s(%s)" tool_count last_tool outcome
    | None ->
      (* The injector writes every key together, so tool context with
         partial tool keys is corruption worth a warning; a fresh context
         simply has nothing to say yet. *)
      if tool_context_exists
      then
        Log.Keeper.warn
          "Temporal summary omits tools: missing tool summary keys (%s/%s/%s)"
          key_tool_call_count key_last_tool_name key_last_tool_outcome;
      ""
  in
  Printf.sprintf "[Temporal] time=%s%s%s" wall_time elapsed_part tools_part
