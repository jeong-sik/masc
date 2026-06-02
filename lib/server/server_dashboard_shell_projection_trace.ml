(* Per-request projection-timing tracker for dashboard shell endpoints.

   Encapsulates the mutable trace state (Hashtbl + Stdlib.Mutex) and the
   start/finish/snapshot lifecycle. Each cache_key (typically a config
   partition + light flag) gets exactly one trace; later starts overwrite. *)

type shell_projection_timing =
  { projection_label : string
  ; projection_ms : int
  }

type shell_projection_trace_status =
  | Shell_trace_running
  | Shell_trace_finished
  | Shell_trace_failed

type shell_projection_trace =
  { trace_light : bool
  ; trace_started_at : float
  ; mutable trace_status : shell_projection_trace_status
  ; mutable trace_active : string list
  ; mutable trace_completed : shell_projection_timing list
  ; mutable trace_finished_at : float option
  }

type shell_projection_trace_snapshot =
  { snapshot_status : shell_projection_trace_status
  ; snapshot_light : bool
  ; snapshot_elapsed_ms : int
  ; snapshot_active : string list
  ; snapshot_completed : shell_projection_timing list
  ; snapshot_finished_at : float option
  }

let mu = Stdlib.Mutex.create ()
let traces : (string, shell_projection_trace) Hashtbl.t = Hashtbl.create 16

let status_string = function
  | Shell_trace_running -> "running"
  | Shell_trace_finished -> "finished"
  | Shell_trace_failed -> "failed"
;;

let timing_top timings =
  timings
  |> List.sort (fun left right -> compare right.projection_ms left.projection_ms)
  |> List.filteri (fun idx _ -> idx < 5)
;;

let timing_json timing =
  `Assoc [ "label", `String timing.projection_label; "ms", `Int timing.projection_ms ]
;;

let timing_log timings =
  match timing_top timings with
  | [] -> "none"
  | top ->
    top
    |> List.map (fun timing ->
      Printf.sprintf "%s=%dms" timing.projection_label timing.projection_ms)
    |> String.concat ","
;;

let start ~cache_key ~light =
  let trace =
    { trace_light = light
    ; trace_started_at = Unix.gettimeofday ()
    ; trace_status = Shell_trace_running
    ; trace_active = []
    ; trace_completed = []
    ; trace_finished_at = None
    }
  in
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.replace traces cache_key trace);
  trace
;;

let start_projection trace label =
  Stdlib.Mutex.protect mu (fun () ->
    if not (List.mem label trace.trace_active)
    then trace.trace_active <- label :: trace.trace_active)
;;

let finish_projection trace label elapsed_ms =
  Stdlib.Mutex.protect mu (fun () ->
    trace.trace_active
    <- List.filter (fun active -> not (String.equal active label)) trace.trace_active;
    trace.trace_completed
    <- { projection_label = label; projection_ms = elapsed_ms }
       :: List.filter
            (fun timing -> not (String.equal timing.projection_label label))
            trace.trace_completed)
;;

let finish ?(clear_active = true) trace status =
  Stdlib.Mutex.protect mu (fun () ->
    trace.trace_status <- status;
    trace.trace_finished_at <- Some (Unix.gettimeofday ());
    if clear_active then trace.trace_active <- [])
;;

let snapshot cache_key =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt traces cache_key with
    | None -> None
    | Some trace ->
      let now_ts = Unix.gettimeofday () in
      let finished_at = trace.trace_finished_at in
      let elapsed_until = Option.value finished_at ~default:now_ts in
      Some
        { snapshot_status = trace.trace_status
        ; snapshot_light = trace.trace_light
        ; snapshot_elapsed_ms =
            int_of_float ((elapsed_until -. trace.trace_started_at) *. 1000.0)
        ; snapshot_active = trace.trace_active
        ; snapshot_completed = trace.trace_completed
        ; snapshot_finished_at = finished_at
        })
;;

let diagnostics cache_key =
  match snapshot cache_key with
  | None ->
    [ "projection_timing_status", `String "none"
    ; "projection_timing_active", `List []
    ; "projection_timing_top", `List []
    ]
  | Some snap ->
    [ "projection_timing_status", `String (status_string snap.snapshot_status)
    ; "projection_timing_light", `Bool snap.snapshot_light
    ; "projection_timing_elapsed_ms", `Int snap.snapshot_elapsed_ms
    ; ( "projection_timing_active"
      , `List (List.rev snap.snapshot_active |> List.map (fun label -> `String label)) )
    ; ( "projection_timing_top"
      , `List (timing_top snap.snapshot_completed |> List.map timing_json) )
    ; ( "projection_timing_finished_at"
      , match snap.snapshot_finished_at with
        | Some ts -> `Float ts
        | None -> `Null )
    ]
;;

let log cache_key =
  match snapshot cache_key with
  | None -> "none", "none", "none", 0
  | Some snap ->
    ( status_string snap.snapshot_status
    , (match List.rev snap.snapshot_active with
       | [] -> "none"
       | active -> String.concat "," active)
    , timing_log snap.snapshot_completed
    , snap.snapshot_elapsed_ms )
;;
