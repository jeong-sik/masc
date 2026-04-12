(** Keeper_trace_emit — TLA+ trace validation용 상태 전이 기록.

    MASC_TLA_TRACE=1 일 때만 활성.
    conditions_to_json 재사용으로 14필드 전체 기록. *)

module SM = Keeper_state_machine

(* This flag is queried from registry/test code that can run before an Eio
   scheduler exists, so the cache must stay on Stdlib.Lazy. *)
let enabled_cache =
  lazy
    (match Sys.getenv_opt "MASC_TLA_TRACE" with
     | Some ("1" | "true" | "yes") -> true
     | _ -> false)

let enabled () = Lazy.force enabled_cache

let trace_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat base_path ".masc") "keepers")
    (keeper_name ^ ".tla-trace.jsonl")

let emit_transition
    ~(keeper_name : string)
    ~(base_path : string)
    ~(seq : int)
    ~(event : SM.event)
    ~(prev_phase : SM.phase)
    ~(new_phase : SM.phase)
    ~(conditions_after : SM.conditions)
    ~(restart_count : int)
  =
  if not (Lazy.force enabled_cache) then ()
  else
    let json = `Assoc [
      "seq", `Int seq;
      "ts_unix", `Float (Time_compat.now ());
      "event", `String (SM.event_to_string event);
      "prev_phase", `String (SM.phase_to_string prev_phase);
      "new_phase", `String (SM.phase_to_string new_phase);
      "conditions_after", SM.conditions_to_json conditions_after;
      "restart_count", `Int restart_count;
    ] in
    let path = trace_path ~base_path ~keeper_name in
    try Keeper_types_support.append_jsonl_line path json
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Printf.eprintf "trace_emit: %s: %s\n%!"
        keeper_name (Printexc.to_string exn)
