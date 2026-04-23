type phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

type t = {
  phase : phase;
  state_ready : bool;
  backend_mode : string;
  pending_lazy_tasks : string list;
  last_error : string option;
  fallback_reason : string option;
  path_diagnostics : Yojson.Safe.t option;
  config_resolution : Yojson.Safe.t option;
  started_at : float;
}

(* ── Backend string <-> product phase mapping ───────────── *)

let backend_phase_of_string s =
  match String.lowercase_ascii s with
  | "filesystem" | "fs" -> Some Server_state_product.Backend.Filesystem
  | "degraded" -> Some Server_state_product.Backend.Degraded
  | "uninitialized" | "unknown" -> Some Server_state_product.Backend.Uninitialized
  | _ -> None

let backend_phase_to_string = function
  | Server_state_product.Backend.Filesystem -> "filesystem"
  | Server_state_product.Backend.Degraded -> "degraded"
  | Server_state_product.Backend.Uninitialized -> "unknown"

(* ── Flat record <-> product state conversion ───────────── *)

let to_product (current : t) : Server_state_product.product =
  let open Server_state_product in
  let lifecycle =
    match current.phase with
    | Blocking -> Lifecycle.Booting
    | Ready | Lazy | Degraded -> Lifecycle.Serving
  in
  let backend =
    match backend_phase_of_string current.backend_mode with
    | Some b -> b
    | None -> Server_state_product.Backend.Uninitialized
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
    backend;
    lazy_tasks;
    readiness;
    last_error = current.last_error;
    fallback_reason = current.fallback_reason;
  }

(* Backward-compatible flat-phase derivation.
   The legacy model maps lazy-task failures to [Degraded] even when the
   backend is healthy. We preserve that by checking [last_error]. *)
let derive_phase (product : Server_state_product.product) : phase =
  let open Server_state_product in
  match product.last_error with
  | Some _ when product.lifecycle = Lifecycle.Serving
                && product.readiness = Readiness.Ready ->
      Degraded
  | _ ->
      (match derive_flat_phase product with
       | Blocking -> Blocking
       | Lazy -> Lazy
       | Ready -> Ready
       | Degraded -> Degraded)

let of_product (product : Server_state_product.product) (started_at : float)
    (path_diagnostics : Yojson.Safe.t option)
    (config_resolution : Yojson.Safe.t option) : t =
  let open Server_state_product in
  {
    phase = derive_phase product;
    state_ready = (product.readiness = Readiness.Ready);
    backend_mode = backend_phase_to_string product.backend;
    pending_lazy_tasks =
      (match product.lazy_tasks with
       | Lazy_task_queue.Complete -> []
       | Lazy_task_queue.Pending tasks -> tasks);
    last_error = product.last_error;
    fallback_reason = product.fallback_reason;
    path_diagnostics;
    config_resolution;
    started_at;
  }

(* ── State reference ────────────────────────────────────── *)

let state =
  ref
    {
      phase = Blocking;
      state_ready = false;
      backend_mode = "unknown";
      pending_lazy_tasks = [];
      last_error = None;
      fallback_reason = None;
      path_diagnostics = None;
      config_resolution = None;
      started_at = Unix.gettimeofday ();
    }

let update f = state := f !state

let phase_to_string = function
  | Blocking -> "blocking"
  | Lazy -> "lazy"
  | Ready -> "ready"
  | Degraded -> "degraded"

(* ── Observation ────────────────────────────────────────── *)

let is_live () = true

let elapsed_since_start () =
  Unix.gettimeofday () -. !state.started_at

let default_watchdog_timeout_sec = 240.0

let watchdog_timeout_sec () = Env_config.Transport.startup_watchdog_sec ()

let pending_lazy_tasks () =
  !state.pending_lazy_tasks

let lazy_tasks_complete () =
  !state.pending_lazy_tasks = []

(* ── Transitions (with product-state invariant checking) ── *)

let reset ?(backend_mode = "unknown") () =
  state :=
    {
      phase = Blocking;
      state_ready = false;
      backend_mode;
      pending_lazy_tasks = [];
      last_error = None;
      fallback_reason = None;
      path_diagnostics = None;
      config_resolution = None;
      started_at = Unix.gettimeofday ();
    }

let mark_blocking ~backend_mode =
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
      (* I5: Booting => backend must be Uninitialized. *)
      let product = { product with backend = Backend.Uninitialized } in
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

let mark_state_ready ~backend_mode =
  update (fun current ->
      let open Server_state_product in
      let product = to_product current in
      (* Resolve backend if still uninitialized. *)
      let product =
        match product.backend with
        | Backend.Uninitialized ->
            let event =
              match String.lowercase_ascii backend_mode with
              | "filesystem" | "fs" -> Some Backend.Resolve_fs
              | _ -> None
            in
            (match event with
             | Some ev ->
                 (match apply_backend_event product ev with
                  | Ok p -> p
                  | Error _ -> product)
             | None -> product)
        | _ -> product
      in
      (* Boot complete if still booting. *)
      let product =
        match product.lifecycle with
        | Lifecycle.Booting ->
            (match apply_lifecycle_event product Boot_complete with
             | Ok p -> p
             | Error _ -> product)
        | _ -> product
      in
      (* Set ready if not already. *)
      let product =
        match product.readiness with
        | Readiness.NotReady ->
            (match apply_readiness_event product Set_ready with
             | Ok p -> p
             | Error _ -> product)
        | Readiness.Ready -> product
      in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

let activate_lazy ~backend_mode ~tasks =
  update (fun current ->
      let open Server_state_product in
      let product = to_product current in
      (* Resolve backend. *)
      let product =
        match product.backend with
        | Backend.Uninitialized ->
            let event =
              match String.lowercase_ascii backend_mode with
              | "filesystem" | "fs" -> Some Backend.Resolve_fs
              | _ -> None
            in
            (match event with
             | Some ev ->
                 (match apply_backend_event product ev with
                  | Ok p -> p
                  | Error _ -> product)
             | None -> product)
        | _ -> product
      in
      (* Boot complete. *)
      let product =
        match product.lifecycle with
        | Lifecycle.Booting ->
            (match apply_lifecycle_event product Boot_complete with
             | Ok p -> p
             | Error _ -> product)
        | _ -> product
      in
      (* Set ready. *)
      let product =
        match product.readiness with
        | Readiness.NotReady ->
            (match apply_readiness_event product Set_ready with
             | Ok p -> p
             | Error _ -> product)
        | Readiness.Ready -> product
      in
      (* Apply lazy tasks. *)
      let product =
        if tasks <> [] then
          match apply_lazy_event product (Tasks_appear tasks) with
          | Ok p -> p
          | Error _ -> product
        else product
      in
      of_product product current.started_at current.path_diagnostics
        current.config_resolution)

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

let note_fallback reason =
  update (fun current ->
      let product = to_product current in
      let product = { product with fallback_reason = Some reason } in
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
  let current = !state in
  let product = to_product current in
  `Assoc
    [
      ("phase", `String (phase_to_string current.phase));
      ("state_ready", `Bool current.state_ready);
      ("backend_mode", `String current.backend_mode);
      ( "pending_lazy_tasks",
        `List (List.map (fun task -> `String task) current.pending_lazy_tasks)
      );
      ( "last_error",
        match current.last_error with
        | Some error -> `String error
        | None -> `Null );
      ( "fallback_reason",
        match current.fallback_reason with
        | Some reason -> `String reason
        | None -> `Null );
      ( "path_diagnostics",
        match current.path_diagnostics with
        | Some value -> value
        | None -> `Null );
      ( "config_resolution",
        match current.config_resolution with
        | Some value -> value
        | None -> `Null );
      ("elapsed_sec", `Float (elapsed_since_start ()));
      ("watchdog_timeout_sec", `Float (watchdog_timeout_sec ()));
      ("product", Server_state_product.product_to_json product);
    ]
