type component = Projection | Task_product | Retained_turn_surface
type decision = Constructed | Reused
type outcome = In_progress | Returned | Returned_error | Raised | Cancelled
type coverage = Fiber_capture | Non_eio_unobserved

type sample =
  { component : component
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; descriptor_count : int
  ; entered_ns : int64
  ; lookup_finished_ns : int64 option
  ; lock_acquired_ns : int64 option
  ; decision_ns : int64 option
  ; decision : decision option
  ; finished_ns : int64 option
  ; outcome : outcome
  }

type report =
  { coverage : coverage
  ; elapsed_ns : int64
  ; outcome : outcome
  ; samples : sample list
  }

type collection = Open of sample Atomic.t list | Closed
type capture = { started : Mtime.t; samples : collection Atomic.t }
type access = Unobserved | Observed of capture * sample Atomic.t

let capture_key : capture Eio.Fiber.key = Eio.Fiber.create_key ()
let elapsed capture = Mtime.Span.to_uint64_ns (Mtime.span capture.started (Mtime_clock.now ()))

let rec update cell f =
  let previous = Atomic.get cell in
  if not (Atomic.compare_and_set cell previous (f previous)) then update cell f
;;

let rec admit capture sample =
  match Atomic.get capture.samples with
  | Closed -> Unobserved
  | Open samples as previous ->
    if Atomic.compare_and_set capture.samples previous (Open (sample :: samples))
    then Observed (capture, sample)
    else admit capture sample
;;

let mark access f = match access with
  | Unobserved -> ()
  | Observed (capture, sample) ->
    let now = elapsed capture in
    update sample (fun previous -> f now previous)
;;

let lookup_finished access = mark access (fun now sample -> {sample with lookup_finished_ns=Some now})
let lock_acquired access = mark access (fun now sample -> {sample with lock_acquired_ns=Some now})
let decided access decision = mark access (fun now sample -> {sample with decision_ns=Some now;decision=Some decision})
let finish access outcome = mark access (fun now sample -> {sample with finished_ns=Some now;outcome})

let cache_access component ~snapshot ~descriptor_count operation =
  let capture = match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> None
    | Eio_fiber -> Eio.Fiber.get capture_key in
  let access = match capture with
    | None -> Unobserved
    | Some capture ->
      let sample = Atomic.make
          { component; snapshot_revision=Skill_catalog_snapshot.snapshot_revision snapshot
          ; descriptor_count=descriptor_count (); entered_ns=elapsed capture
          ; lookup_finished_ns=None; lock_acquired_ns=None; decision_ns=None; decision=None
          ; finished_ns=None; outcome=In_progress } in
      admit capture sample
  in
  match operation access with
  | value -> finish access Returned; value
  | exception error ->
    let backtrace = Printexc.get_raw_backtrace () in
    finish access (match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised);
    Printexc.raise_with_backtrace error backtrace
;;

let capture_result ~on_report operation =
  let capture = {started=Mtime_clock.now ();samples=Atomic.make (Open [])} in
  let coverage = match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> Non_eio_unobserved
    | Eio_fiber -> Fiber_capture in
  let report outcome =
    let samples = match Atomic.exchange capture.samples Closed with
      | Closed -> []
      | Open samples -> List.rev_map Atomic.get samples in
    (* Read the end clock after freezing admission and copying sample states.
       A child settling concurrently cannot place a sampled finish beyond the
       report's own interval. Later updates cannot change these immutable rows. *)
    let elapsed_ns = elapsed capture in
    let report = {coverage;elapsed_ns;outcome;samples} in
    try on_report report with
    | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as error -> raise error
    | error ->
      (try Log.Keeper.warn "Skill preparation observation sink failed: %s" (Printexc.to_string error) with
       | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as error -> raise error
       | _ -> ())
  in
  let run () = match coverage with
    | Non_eio_unobserved -> operation ()
    | Fiber_capture -> Eio.Fiber.with_binding capture_key capture operation in
  match run () with
  | result -> report (match result with Ok _ -> Returned | Error _ -> Returned_error); result
  | exception error ->
    let backtrace = Printexc.get_raw_backtrace () in
    let emit () = report (match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised) in
    (match coverage with Fiber_capture -> Eio.Cancel.protect emit | Non_eio_unobserved -> emit ());
    Printexc.raise_with_backtrace error backtrace
;;

let component_name = function Projection -> "projection" | Task_product -> "task_product" | Retained_turn_surface -> "retained_turn_surface"
let outcome_to_string = function In_progress -> "in_progress" | Returned -> "returned" | Returned_error -> "returned_error" | Raised -> "raised" | Cancelled -> "cancelled"
let decision_json = function None -> `Null | Some Constructed -> `String "constructed" | Some Reused -> `String "reused"
let ns value = `String (Int64.to_string value)
let optional_ns = function None -> `Null | Some value -> ns value

let report_to_json (report : report) =
  let sample_json (sample : sample) = `Assoc
      [ "component",`String (component_name sample.component)
      ; "snapshot_revision",`String (Skill_catalog_snapshot.snapshot_revision_to_string sample.snapshot_revision)
      ; "descriptor_count",`Int sample.descriptor_count
      ; "entered_ns",ns sample.entered_ns; "lookup_finished_ns",optional_ns sample.lookup_finished_ns
      ; "lock_acquired_ns",optional_ns sample.lock_acquired_ns; "decision_ns",optional_ns sample.decision_ns
      ; "decision",decision_json sample.decision; "finished_ns",optional_ns sample.finished_ns
      ; "outcome",`String (outcome_to_string sample.outcome) ] in
  `Assoc [ "schema_version",`Int 1; "clock",`String "capture_monotonic_offsets"
         ; "coverage",`String (match report.coverage with Fiber_capture -> "fiber_capture" | Non_eio_unobserved -> "non_eio_unobserved")
         ; "elapsed_ns",ns report.elapsed_ns; "outcome",`String (outcome_to_string report.outcome)
         ; "samples",`List (List.map sample_json report.samples) ]
;;

