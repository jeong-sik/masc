(** Masc_context_injector — OAS context_injector for MASC agents.

    @since context_injector integration *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type config = { start_time : float }

let default_config () : config = { start_time = Unix.gettimeofday () }

(* ================================================================ *)
(* Context keys                                                      *)
(* ================================================================ *)

let key_wall_time = "session:wall_time"
let key_elapsed_seconds = "session:elapsed_seconds"
let key_tool_call_count = "session:tool_call_count"
let key_last_tool_name = "session:last_tool_name"
let key_last_tool_outcome = "session:last_tool_outcome"
let key_tool_success_count = "session:tool_success_count"
let key_tool_error_count = "session:tool_error_count"

(* ================================================================ *)
(* ISO 8601 formatting                                               *)
(* ================================================================ *)

let iso8601_of_float (t : float) : string =
  let open Unix in
  let tm = gmtime t in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
;;

(* ================================================================ *)
(* Injector factory                                                  *)
(* ================================================================ *)

let make ~(config : config) () : Oas.Hooks.context_injector =
  let call_count = Atomic.make 0 in
  let success_count = Atomic.make 0 in
  let error_count = Atomic.make 0 in
  fun ~tool_name ~input:_ ~output ->
    let now = Unix.gettimeofday () in
    let is_ok =
      match output with
      | Ok _ -> true
      | Error _ -> false
    in
    let _ = Atomic.fetch_and_add call_count 1 in
    if is_ok
    then ignore (Atomic.fetch_and_add success_count 1)
    else ignore (Atomic.fetch_and_add error_count 1);
    let outcome_str = if is_ok then "ok" else "error" in
    let elapsed = now -. config.start_time in
    Some
      Oas.Hooks.
        { context_updates =
            [ key_wall_time, `String (iso8601_of_float now)
            ; key_elapsed_seconds, `Float elapsed
            ; key_tool_call_count, `Int (Atomic.get call_count)
            ; key_last_tool_name, `String tool_name
            ; key_last_tool_outcome, `String outcome_str
            ; key_tool_success_count, `Int (Atomic.get success_count)
            ; key_tool_error_count, `Int (Atomic.get error_count)
            ]
        ; extra_messages = []
        }
;;

(* ================================================================ *)
(* Temporal summary renderer                                         *)
(* ================================================================ *)

let get_string ctx key =
  match Oas.Context.get ctx key with
  | Some (`String s) -> Some s
  | _ -> None
;;

let get_float ctx key =
  match Oas.Context.get ctx key with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let get_int ctx key =
  match Oas.Context.get ctx key with
  | Some (`Int i) -> Some i
  | _ -> None
;;

let render_temporal_summary (ctx : Oas.Context.t) : string option =
  match get_string ctx key_wall_time with
  | None -> None
  | Some wall_time ->
    let elapsed = get_float ctx key_elapsed_seconds |> Option.value ~default:0.0 in
    let tool_count = get_int ctx key_tool_call_count |> Option.value ~default:0 in
    let last_tool = get_string ctx key_last_tool_name |> Option.value ~default:"none" in
    let outcome =
      get_string ctx key_last_tool_outcome |> Option.value ~default:"unknown"
    in
    Some
      (Printf.sprintf
         "[Temporal] time=%s elapsed=%.0fs tools=%d last=%s(%s)"
         wall_time
         elapsed
         tool_count
         last_tool
         outcome)
;;
