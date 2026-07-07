(* RFC-0313 W1 — observe-only pacing shadow. See keeper_pacing_shadow.mli. *)

let mu = Eio.Mutex.create ()
let table : (string, Keeper_pacing.t) Hashtbl.t = Hashtbl.create 64

let catalog_runtime_ids () =
  match Runtime.get_runtime_ids () with
  | [] -> []
  | ids -> ids

let emit_telemetry ~keeper_name ~runtime_id ~kind ~state ~now =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string PacingShadowEvents)
    ~labels:[ "keeper", keeper_name; "runtime", runtime_id; "kind", kind ]
    ();
  match catalog_runtime_ids () with
  | [] -> ()
  | catalog ->
    let due = Keeper_pacing.next_turn_due ~catalog ~now state in
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string PacingShadowNextDueSec)
      ~labels:[ "keeper", keeper_name ]
      (Float.max 0.0 (due -. now))

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
      ~policy:Keeper_pacing.default_policy
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
