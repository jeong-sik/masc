(* RFC-0313 W1/W3 — process-wide pacing state store. See keeper_pacing_shadow.mli. *)

let mu = Eio.Mutex.create ()
let table : (string, Keeper_pacing.t) Hashtbl.t = Hashtbl.create 64

(* [Keeper_pacing.t] is abstract; the observed runtime ids come from its
   observability projection. #23524 landed this helper reading [state] as a
   bare assoc list, which does not typecheck against the abstract [t]. *)
let observed_runtime_ids state = List.map fst (Keeper_pacing.to_summary state)

let next_due_remaining_of_state ~now state =
  match observed_runtime_ids state with
  | [] -> None
  | catalog ->
    let due = Keeper_pacing.next_turn_due ~catalog ~now state in
    let remaining = due -. now in
    if remaining > 0.0 then Some remaining else None

let policy_of_runtime () =
  let p = Runtime.pacing () in
  { Keeper_pacing.base_sec = p.Runtime_schema.pacing_base_sec
  ; multiplier = p.Runtime_schema.pacing_multiplier
  ; cap_sec = p.Runtime_schema.pacing_cap_sec
  }

let pacing_enforced () =
  match (Runtime.pacing ()).Runtime_schema.pacing_mode with
  | Runtime_schema.Pacing_enforce -> true
  | Runtime_schema.Pacing_shadow -> false

let emit_telemetry ~keeper_name ~runtime_id ~kind ~state ~now =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string PacingShadowEvents)
    ~labels:[ "keeper", keeper_name; "runtime", runtime_id; "kind", kind ]
    ();
  match next_due_remaining_of_state ~now state with
  | None ->
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string PacingShadowNextDueSec)
      ~labels:[ "keeper", keeper_name ]
      0.0
  | Some remaining ->
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string PacingShadowNextDueSec)
      ~labels:[ "keeper", keeper_name ]
      remaining

let update ~keeper_name ~runtime_id ~kind f =
  let now = Time_compat.now () in
  let state =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      let prev =
        match Hashtbl.find_opt table keeper_name with
        | Some state -> state
        | None -> Keeper_pacing.empty
      in
      let next = f ~now prev in
      Hashtbl.replace table keeper_name next;
      next)
  in
  emit_telemetry ~keeper_name ~runtime_id ~kind ~state ~now

let observe_failure ~keeper_name ~runtime_id ~retry_after =
  update ~keeper_name ~runtime_id ~kind:"failure" (fun ~now state ->
    Keeper_pacing.on_failure
      ~policy:(policy_of_runtime ())
      ~runtime_id
      ~retry_after
      ~now
      state)

let observe_success ~keeper_name ~runtime_id =
  update ~keeper_name ~runtime_id ~kind:"success" (fun ~now:_ state ->
    Keeper_pacing.on_success ~runtime_id state)

let snapshot ~keeper_name =
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    match Hashtbl.find_opt table keeper_name with
    | Some state -> Keeper_pacing.to_summary state
    | None -> [])

let next_due_remaining ~keeper_name =
  let now = Time_compat.now () in
  let state =
    Eio.Mutex.use_rw ~protect:true mu (fun () -> Hashtbl.find_opt table keeper_name)
  in
  match state with
  | None -> None
  | Some state -> next_due_remaining_of_state ~now state

let remaining_for_runtime ~keeper_name ~runtime_id =
  let now = Time_compat.now () in
  let revisit =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      Option.bind
        (Hashtbl.find_opt table keeper_name)
        (Keeper_pacing.revisit_of ~runtime_id))
  in
  match revisit with
  | None -> None
  | Some revisit ->
    let remaining = revisit.Keeper_pacing.eligible_at -. now in
    if remaining > 0.0 then Some remaining else None
;;
