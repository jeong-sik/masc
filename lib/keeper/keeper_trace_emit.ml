(** Keeper_trace_emit — TLA+ trace validation용 상태 전이 기록.

    MASC_TLA_TRACE=1 일 때만 활성.
    conditions_to_json 재사용으로 14필드 전체 기록. *)

module SM = Keeper_state_machine
module SMJ = Keeper_state_machine_json
(* SM owns the [conditions] record type; SMJ owns its JSON projection
   (extracted to break a wrapping cycle between the state-machine core
   and yojson surface code).  Two-line module rebind so callsites read
   [SMJ.conditions_to_json] without re-importing the full path. *)

(* This flag is queried from registry/test code that can run before an Eio
   scheduler exists, so it cannot depend on Eio.Lazy.  Use a plain
   Atomic+Stdlib.Mutex memo instead of Stdlib.Lazy.force, which is not the
   concurrency primitive we use elsewhere in the Eio runtime. *)
let enabled_cache : bool option Atomic.t = Atomic.make None
let enabled_cache_mu = Mutex.create ()

let compute_enabled () =
  match Sys.getenv_opt "MASC_TLA_TRACE" with
  | Some ("1" | "true" | "yes") -> true
  | _ -> false

let enabled () =
  match Atomic.get enabled_cache with
  | Some enabled -> enabled
  | None ->
      Mutex.protect enabled_cache_mu (fun () ->
        match Atomic.get enabled_cache with
        | Some enabled -> enabled
        | None ->
            let enabled = compute_enabled () in
            Atomic.set enabled_cache (Some enabled);
            enabled)

let trace_path ~base_path ~keeper_name =
  Filename.concat
    (Common.keepers_runtime_dir_of_base ~base_path)
    (Keeper_runtime_root_entry.keeper_basename
       ~keeper_name
       Keeper_runtime_root_entry.Tla_trace_log)

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
  if not (enabled ()) then ()
  else
    let json = `Assoc [
      "seq", `Int seq;
      "ts_unix", `Float (Time_compat.now ());
      "event", `String (SM.event_to_string event);
      "prev_phase", `String (SM.phase_to_string prev_phase);
      "new_phase", `String (SM.phase_to_string new_phase);
      "conditions_after", SMJ.conditions_to_json conditions_after;
      "restart_count", `Int restart_count;
    ] in
    let path = trace_path ~base_path ~keeper_name in
    try Keeper_types_support.append_jsonl_line path json
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string TraceEmitFailures)
          ~labels:[("keeper", keeper_name)]
          ();
        Log.Keeper.warn "trace_emit: %s: %s"
          keeper_name (Printexc.to_string exn)
