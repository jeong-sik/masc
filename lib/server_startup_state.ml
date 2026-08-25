type phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

type t = {
  phase : phase;
  state_ready : bool;
  pending_lazy_tasks : string list;
  last_error : string option;
  path_diagnostics : Yojson.Safe.t option;
  config_resolution : Yojson.Safe.t option;
  started_at : float;
}

(* ── Flat record <-> product state conversion ───────────── *)

let to_product (current : t) : Server_state_product.product =
  let open Server_state_product in
  let lifecycle =
    match current.phase with
    | Blocking -> Lifecycle.Booting
    | Ready | Lazy | Degraded -> Lifecycle.Serving
  in
  let lazy_tasks =
    match current.pending_lazy_tasks with
    | [] -> Lazy_task_queue.Complete
    | tasks -> Lazy_task_queue.Pending tasks
  in
  let readiness =
    if current.state_ready then Readiness.Ready else Readiness.NotReady
  in
  {
    lifecycle;
    lazy_tasks;
    readiness;
    last_error = current.last_error;
  }

let derive_phase (product : Server_state_product.product) : phase =
  let open Server_state_product in
  match derive_flat_phase product with
  | Blocking -> Blocking
  | Lazy -> Lazy
  | Ready -> Ready
  | Degraded -> Degraded

let of_product (product : Server_state_product.product) (started_at : float)
    (path_diagnostics : Yojson.Safe.t option)
    (config_resolution : Yojson.Safe.t option) : t =
  let open Server_state_product in
  {
    phase = derive_phase product;
    state_ready = (product.readiness = Readiness.Ready);
    pending_lazy_tasks =
      (match product.lazy_tasks with
       | Lazy_task_queue.Complete -> []
       | Lazy_task_queue.Pending tasks -> tasks);
    last_error = product.last_error;
    path_diagnostics;
    config_resolution;
    started_at;
  }

(* ── State reference ────────────────────────────────────── *)

let initial_state () =
    {
      phase = Blocking;
      state_ready = false;
      pending_lazy_tasks = [];
      last_error = None;
      path_diagnostics = None;
      config_resolution = None;
      started_at = Unix.gettimeofday ();
    }

let state = Atomic.make (initial_state ())

let snapshot () = Atomic.get state

let update f = Atomic_util.update state f

(* NDT-OK: startup elapsed time is operational telemetry and timeout budgeting;
   wall-clock sampling is confined to this observation boundary. *)
let wall_clock_now = Unix.gettimeofday

let phase_to_string = function
  | Blocking -> "blocking"
  | Lazy -> "lazy"
  | Ready -> "ready"
  | Degraded -> "degraded"

(* ── Observation ────────────────────────────────────────── *)

let is_live () = true

let elapsed_since_start () =
  wall_clock_now () -. (snapshot ()).started_at

let watchdog_timeout_sec () = Env_config.Transport.startup_watchdog_sec ()

let pending_lazy_tasks () =
  (snapshot ()).pending_lazy_tasks

(* ── Transitions (with product-state invariant checking) ── *)

let reset () =
  Atomic.set state (initial_state ())

let mark_blocking () =
  update (fun current ->
      let open Server_state_product in
      let product = to_product current in
      (* Transition lifecycle toward Booting via Stopped if needed. *)
      let product =
        match product.lifecycle with
        | Lifecycle.Serving ->
            (match apply_lifecycle_event product Start_draining with
             | Ok p ->
                 (match apply_lifecycle_event p Stop with
                  | Ok p2 -> p2
                  | Error _ -> p)
             | Error _ -> product)
        | Lifecycle.Draining ->
            (match apply_lifecycle_event product Stop with
             | Ok p -> p
             | Error _ -> product)
        | Lifecycle.Stopped | Lifecycle.Booting -> product
      in
      (* Readiness to NotReady. *)
      let product =
        match product.readiness with
        | Readiness.Ready ->
            (match apply_readiness_event product Set_not_ready with
             | Ok p -> p
             | Error _ -> product)
        | Readiness.NotReady -> product
      in
      let product = { product with lazy_tasks = Lazy_task_queue.Complete } in
      let product = { product with last_error = None } in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

type state_ready_transition_stage =
  | Boot_completion
  | Readiness_publication

type state_ready_error =
  | State_ready_transition_rejected of
      { stage : state_ready_transition_stage
      ; reason : string
      }

let state_ready_transition_stage_to_string = function
  | Boot_completion -> "boot_completion"
  | Readiness_publication -> "readiness_publication"

let state_ready_error_to_string = function
  | State_ready_transition_rejected { stage; reason } ->
    Printf.sprintf
      "server ready transition rejected at %s: %s"
      (state_ready_transition_stage_to_string stage)
      reason

let transition_error stage reason =
  Error (State_ready_transition_rejected { stage; reason })

let rec mark_state_ready () =
  let current = snapshot () in
  let open Server_state_product in
  let product = to_product current in
  let after_boot =
    match product.lifecycle with
    | Lifecycle.Booting ->
      Result.map_error
        (fun reason -> State_ready_transition_rejected
            { stage = Boot_completion; reason })
        (apply_lifecycle_event product Lifecycle.Boot_complete)
    | Lifecycle.Serving -> Ok product
    | Lifecycle.Draining | Lifecycle.Stopped ->
      transition_error
        Boot_completion
        (Printf.sprintf
           "lifecycle=%s cannot publish startup readiness"
           (Lifecycle.phase_to_string product.lifecycle))
  in
  let ready =
    Result.bind after_boot (fun product ->
      match product.readiness with
      | Readiness.NotReady ->
        Result.map_error
          (fun reason -> State_ready_transition_rejected
              { stage = Readiness_publication; reason })
          (apply_readiness_event product Readiness.Set_ready)
      | Readiness.Ready ->
        Result.map (fun () -> product) (check_invariants product)
        |> Result.map_error (fun reason ->
          State_ready_transition_rejected
            { stage = Readiness_publication; reason }))
  in
  match ready with
  | Error _ as error -> error
  | Ok product ->
    let next =
      of_product
        product
        current.started_at
        current.path_diagnostics
        current.config_resolution
    in
    if Atomic.compare_and_set state current next
    then Ok ()
    else mark_state_ready ()

type lazy_prepare_error =
  | Lazy_state_transition_rejected of string

let lazy_prepare_error_to_string = function
  | Lazy_state_transition_rejected reason ->
    "lazy startup barrier transition rejected: " ^ reason

let rec prepare_lazy_tasks ~tasks =
  let current = snapshot () in
  let open Server_state_product in
  let product = to_product current in
  let transition =
    if tasks = []
    then Result.map (fun () -> product) (check_invariants product)
    else apply_lazy_event product (Tasks_appear tasks)
  in
  match transition with
  | Error reason -> Error (Lazy_state_transition_rejected reason)
  | Ok prepared ->
    let next =
      of_product
        prepared
        current.started_at
        current.path_diagnostics
        current.config_resolution
    in
    if Atomic.compare_and_set state current next
    then Ok ()
    else prepare_lazy_tasks ~tasks

let finish_lazy_task ~task =
  update (fun current ->
      let open Server_state_product in
      let product = to_product current in
      let product =
        match apply_lazy_event product (Task_finish task) with
        | Ok p -> p
        | Error _ -> product
      in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

let fail_lazy_task ~task ~error =
  update (fun current ->
      let open Server_state_product in
      let product = to_product current in
      let product =
        match apply_lazy_event product (Task_fail { task; error }) with
        | Ok p -> p
        | Error _ -> product
      in
      let product = { product with last_error = Some error } in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

let mark_degraded ~error =
  update (fun current ->
      let product = to_product current in
      let product = { product with last_error = Some error } in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

let note_runtime_resolution ~path_diagnostics ~config_resolution =
  update (fun current ->
      {
        current with
        path_diagnostics = Some path_diagnostics;
        config_resolution = Some config_resolution;
      })

(* ── Serialization ──────────────────────────────────────── *)

let to_yojson () =
  let current = snapshot () in
  let product = to_product current in
  `Assoc
    [
      ("phase", `String (phase_to_string current.phase));
      ("state_ready", `Bool current.state_ready);
      ( "pending_lazy_tasks",
        `List (List.map (fun task -> `String task) current.pending_lazy_tasks)
      );
      ( "last_error", Json_util.string_opt_to_json current.last_error );
      ( "path_diagnostics",
        match current.path_diagnostics with
        | Some value -> value
        | None -> `Null );
      ( "config_resolution",
        match current.config_resolution with
        | Some value -> value
        | None -> `Null );
      ( "elapsed_sec",
        `Float (wall_clock_now () -. current.started_at) );
      ("watchdog_timeout_sec", `Float (watchdog_timeout_sec ()));
      ("product", Server_state_product.product_to_json product);
    ]

module For_testing = struct
  let restore snapshot = Atomic.set state snapshot
end
