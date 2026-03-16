(** Tool-to-Trace correlation hooks

    Connects {!Tool_dispatch} hooks to {!Trace} spans, so every tool
    invocation automatically produces an observable span with tool_name,
    duration, and success/error status.

    Register once at server startup via {!install}.

    @since 2.95.0
*)

(** Per-call state: we store the span in a Hashtbl keyed by a unique call_id
    so the post-hook can find and close it.  This avoids mutable state in the
    result record. *)

let pending_spans : (string, Trace.span) Hashtbl.t = Hashtbl.create 16

let next_call_id =
  let counter = ref 0 in
  fun () ->
    incr counter;
    Printf.sprintf "call-%d-%d"
      !counter
      (int_of_float (Time_compat.now () *. 1000.0))

(** Pre-hook: start a span for this tool call.
    Stores the span keyed by a call_id injected into the result attributes
    (via a naming convention in the tool_name). *)
let pre_hook ~name ~(args : Yojson.Safe.t) =
  let _ = args in
  let call_id = next_call_id () in
  let span = Trace.start_span
    ~operation:(Printf.sprintf "tool:%s" name)
    ~agent:"dispatch"
    ()
  in
  Trace.set_attribute span "tool_name" name;
  Trace.set_attribute span "call_id" call_id;
  Hashtbl.replace pending_spans call_id span;
  None  (* Never short-circuit — observation only *)

(** Post-hook: find the most recent span for this tool and close it. *)
let post_hook (result : Tool_result.t) =
  (* Find the pending span for this tool.
     We match by tool_name since calls are sequential per-fiber. *)
  let found = ref None in
  Hashtbl.iter (fun call_id span ->
    let attrs = span.Trace.attributes in
    if List.exists (fun (k, v) -> k = "tool_name" && v = result.tool_name) attrs
    then found := Some (call_id, span)
  ) pending_spans;
  (match !found with
   | Some (call_id, span) ->
     Trace.set_attribute span "success" (string_of_bool result.success);
     Trace.set_attribute span "duration_ms"
       (Printf.sprintf "%.2f" result.duration_ms);
     let status =
       if result.success then Trace.Ok
       else Trace.Error (
         match result.data with
         | `String s -> s
         | _ -> "tool failed")
     in
     Trace.end_span ~status span;
     Hashtbl.remove pending_spans call_id
   | None -> ());
  result  (* Pass through unmodified *)

(** Install both hooks into {!Tool_dispatch}.
    Call once during server initialization. *)
let install () =
  Tool_dispatch.register_pre_hook pre_hook;
  Tool_dispatch.register_post_hook post_hook
