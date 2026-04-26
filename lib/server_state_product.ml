(** Orthogonal state machine composition — Server Lifecycle x Backend x
    LazyTaskQueue x Readiness.

    Mirrors [specs/server-state/ServerState.tla].

    @since 2.260.0 *)

(* ── Dimension 1: Lifecycle ─────────────────────────────── *)

module Lifecycle = struct
  type phase =
    | Booting
    | Serving
    | Draining
    | Stopped

  let phase_to_string = function
    | Booting -> "booting"
    | Serving -> "serving"
    | Draining -> "draining"
    | Stopped -> "stopped"
  ;;

  let all_phases = [ Booting; Serving; Draining; Stopped ]

  type event =
    | Boot_complete
    | Start_draining
    | Stop

  let event_to_string = function
    | Boot_complete -> "boot_complete"
    | Start_draining -> "start_draining"
    | Stop -> "stop"
  ;;

  type transition =
    | Applied of phase
    | Ignored of
        { phase : phase
        ; event : event
        }

  let apply_event ~current event =
    match current, event with
    | Booting, Boot_complete -> Applied Serving
    | Serving, Start_draining -> Applied Draining
    | Draining, Stop -> Applied Stopped
    | phase, event -> Ignored { phase; event }
  ;;

  let apply_event_lossy ~current event =
    match apply_event ~current event with
    | Applied p | Ignored { phase = p; _ } -> p
  ;;

  let pp_phase fmt p = Format.fprintf fmt "%s" (phase_to_string p)
end

(* ── Dimension 2: Backend ───────────────────────────────── *)

module Backend = struct
  type phase =
    | Uninitialized
    | Filesystem
    | Degraded

  let phase_to_string = function
    | Uninitialized -> "uninitialized"
    | Filesystem -> "filesystem"
    | Degraded -> "degraded"
  ;;

  let all_phases = [ Uninitialized; Filesystem; Degraded ]

  type event =
    | Resolve_fs
    | Degrade of string
    | Recover

  let event_to_string = function
    | Resolve_fs -> "resolve_fs"
    | Degrade s -> "degrade:" ^ s
    | Recover -> "recover"
  ;;

  type transition =
    | Applied of phase
    | Ignored of
        { phase : phase
        ; event : event
        }

  let apply_event ~current event =
    match current, event with
    | Uninitialized, Resolve_fs -> Applied Filesystem
    | Filesystem, Degrade _ -> Applied Degraded
    | Degraded, Recover -> Applied Filesystem
    | phase, event -> Ignored { phase; event }
  ;;

  let apply_event_lossy ~current event =
    match apply_event ~current event with
    | Applied p | Ignored { phase = p; _ } -> p
  ;;

  let pp_phase fmt p = Format.fprintf fmt "%s" (phase_to_string p)
end

(* ── Dimension 3: Lazy Task Queue ───────────────────────── *)

module Lazy_task_queue = struct
  type t =
    | Complete
    | Pending of string list

  let to_string = function
    | Complete -> "complete"
    | Pending tasks -> Printf.sprintf "pending[%d]" (List.length tasks)
  ;;

  let all_states = [ Complete; Pending [] ]

  type event =
    | Tasks_appear of string list
    | Task_finish of string
    | Task_fail of
        { task : string
        ; error : string
        }

  let event_to_string = function
    | Tasks_appear tasks -> Printf.sprintf "tasks_appear[%d]" (List.length tasks)
    | Task_finish task -> "task_finish:" ^ task
    | Task_fail { task; error } -> Printf.sprintf "task_fail:%s:%s" task error
  ;;

  let apply_event ~current event =
    match current, event with
    | Complete, Tasks_appear tasks -> Pending tasks
    | Pending tasks, Task_finish task ->
      let remaining = List.filter (fun t -> t <> task) tasks in
      if remaining = [] then Complete else Pending remaining
    | Pending tasks, Task_fail { task; _ } ->
      let remaining = List.filter (fun t -> t <> task) tasks in
      if remaining = [] then Complete else Pending remaining
    | state, _ -> state
  ;;

  let pp fmt = function
    | Complete -> Format.fprintf fmt "complete"
    | Pending tasks -> Format.fprintf fmt "pending[%d]" (List.length tasks)
  ;;
end

(* ── Dimension 4: Readiness ─────────────────────────────── *)

module Readiness = struct
  type phase =
    | NotReady
    | Ready

  let phase_to_string = function
    | NotReady -> "not_ready"
    | Ready -> "ready"
  ;;

  let all_phases = [ NotReady; Ready ]

  type event =
    | Set_ready
    | Set_not_ready

  let event_to_string = function
    | Set_ready -> "set_ready"
    | Set_not_ready -> "set_not_ready"
  ;;

  type transition =
    | Applied of phase
    | Ignored of
        { phase : phase
        ; event : event
        }

  let apply_event ~current event =
    match current, event with
    | NotReady, Set_ready -> Applied Ready
    | Ready, Set_not_ready -> Applied NotReady
    | phase, event -> Ignored { phase; event }
  ;;

  let apply_event_lossy ~current event =
    match apply_event ~current event with
    | Applied p | Ignored { phase = p; _ } -> p
  ;;

  let pp_phase fmt p = Format.fprintf fmt "%s" (phase_to_string p)
end

(* ── Product State ──────────────────────────────────────── *)

type product =
  { lifecycle : Lifecycle.phase
  ; backend : Backend.phase
  ; lazy_tasks : Lazy_task_queue.t
  ; readiness : Readiness.phase
  ; last_error : string option
  ; fallback_reason : string option
  }

let initial =
  { lifecycle = Lifecycle.Booting
  ; backend = Backend.Uninitialized
  ; lazy_tasks = Lazy_task_queue.Complete
  ; readiness = Readiness.NotReady
  ; last_error = None
  ; fallback_reason = None
  }
;;

(* ── Cross-Dimension Invariants ─────────────────────────── *)

let check_invariants (state : product) : (unit, string) result =
  let violations = ref [] in
  let add v = violations := v :: !violations in
  (* I1: Ready implies not booting *)
  (match state.readiness with
   | Readiness.Ready ->
     (match state.lifecycle with
      | Lifecycle.Booting ->
        add "readiness=Ready but lifecycle=Booting (cannot be ready while booting)"
      | Lifecycle.Serving | Lifecycle.Draining | Lifecycle.Stopped -> ())
   | Readiness.NotReady -> ());
  (* I2: Stopped implies not ready *)
  (match state.lifecycle with
   | Lifecycle.Stopped ->
     (match state.readiness with
      | Readiness.Ready ->
        add "lifecycle=Stopped but readiness=Ready (stopped server is never ready)"
      | Readiness.NotReady -> ())
   | Lifecycle.Booting | Lifecycle.Serving | Lifecycle.Draining -> ());
  (* I3: Pending tasks block stop *)
  (match state.lazy_tasks with
   | Lazy_task_queue.Pending _ ->
     (match state.lifecycle with
      | Lifecycle.Stopped ->
        add "lazy_tasks=Pending but lifecycle=Stopped (cannot stop with pending tasks)"
      | Lifecycle.Booting | Lifecycle.Serving | Lifecycle.Draining -> ())
   | Lazy_task_queue.Complete -> ());
  (* I4: Degraded backend => not ready *)
  (match state.backend with
   | Backend.Degraded ->
     (match state.readiness with
      | Readiness.Ready ->
        add
          "backend=Degraded but readiness=Ready (degraded backend must not serve traffic)"
      | Readiness.NotReady -> ())
   | Backend.Uninitialized | Backend.Filesystem -> ());
  (* I5: Booting => backend uninitialized *)
  (match state.lifecycle with
   | Lifecycle.Booting ->
     (match state.backend with
      | Backend.Uninitialized -> ()
      | _ ->
        add
          (Printf.sprintf
             "lifecycle=Booting but backend=%s (expected Uninitialized)"
             (Backend.phase_to_string state.backend)))
   | Lifecycle.Serving | Lifecycle.Draining | Lifecycle.Stopped -> ());
  match List.rev !violations with
  | [] -> Ok ()
  | vs -> Error (String.concat "; " vs)
;;

(* ── Per-Dimension Event Application ────────────────────── *)

let apply_lifecycle_event state event =
  let new_lifecycle = Lifecycle.apply_event_lossy ~current:state.lifecycle event in
  let new_state = { state with lifecycle = new_lifecycle } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason
;;

let apply_backend_event state event =
  let new_backend = Backend.apply_event_lossy ~current:state.backend event in
  let new_state = { state with backend = new_backend } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason
;;

let apply_lazy_event state event =
  let new_lazy = Lazy_task_queue.apply_event ~current:state.lazy_tasks event in
  let new_state = { state with lazy_tasks = new_lazy } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason
;;

let apply_readiness_event state event =
  let new_readiness = Readiness.apply_event_lossy ~current:state.readiness event in
  let new_state = { state with readiness = new_readiness } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason
;;

(* ── Derived Flat Phase (backward compatibility) ────────── *)

type flat_phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

let derive_flat_phase (state : product) : flat_phase =
  match state.lifecycle, state.backend, state.lazy_tasks, state.readiness with
  | Lifecycle.Booting, _, _, _ -> Blocking
  | _, Backend.Degraded, _, _ -> Degraded
  | Lifecycle.Serving, _, Lazy_task_queue.Pending _, Readiness.Ready -> Lazy
  | Lifecycle.Serving, _, Lazy_task_queue.Complete, Readiness.Ready -> Ready
  | Lifecycle.Draining, _, _, Readiness.Ready -> Ready
  | Lifecycle.Draining, _, _, Readiness.NotReady -> Blocking
  | Lifecycle.Stopped, _, _, _ -> Blocking
  | Lifecycle.Serving, _, _, Readiness.NotReady -> Blocking
;;

let flat_phase_to_string = function
  | Blocking -> "blocking"
  | Lazy -> "lazy"
  | Ready -> "ready"
  | Degraded -> "degraded"
;;

let pp_flat_phase fmt p = Format.fprintf fmt "%s" (flat_phase_to_string p)

(* ── Serialization ──────────────────────────────────────── *)

let product_to_json state =
  `Assoc
    [ "lifecycle", `String (Lifecycle.phase_to_string state.lifecycle)
    ; "backend", `String (Backend.phase_to_string state.backend)
    ; ( "lazy_tasks"
      , match state.lazy_tasks with
        | Lazy_task_queue.Complete -> `String "complete"
        | Lazy_task_queue.Pending tasks ->
          `Assoc [ "pending", `List (List.map (fun t -> `String t) tasks) ] )
    ; "readiness", `String (Readiness.phase_to_string state.readiness)
    ; ( "last_error"
      , match state.last_error with
        | Some e -> `String e
        | None -> `Null )
    ; ( "fallback_reason"
      , match state.fallback_reason with
        | Some r -> `String r
        | None -> `Null )
    ; ( "flat_phase"
      , `String
          (match derive_flat_phase state with
           | Blocking -> "blocking"
           | Lazy -> "lazy"
           | Ready -> "ready"
           | Degraded -> "degraded") )
    ]
;;
