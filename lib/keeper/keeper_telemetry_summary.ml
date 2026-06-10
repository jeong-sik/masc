(** Incremental telemetry summary for fleet health.

    Maintains in-memory incremental counters aggregated from telemetry
    events as they arrive on the OAS event bus.  Avoids O(N) re-scan of
    durable telemetry data — counters are updated on each
    {!record_event} call.

    Thread safety: uses {!Stdlib.Mutex} (not Eio.Mutex) for cross-fiber
    safety without Eio dependency in the health tracker
    (per feedback_ocaml5-mutex-selection.md). *)

type telemetry_entry = {
  timestamp : float;
  keeper_name : string;
  event_kind : string;
  runtime_id : string option;
  duration_ms : float option;
  success : bool;
}

type fleet_snapshot = {
  total_events : int;
  successful_events : int;
  failed_events : int;
  per_keeper : (string, keeper_counters) Hashtbl.t;
  recent_events : telemetry_entry list;
}

and keeper_counters = {
  total : int;
  success : int;
  failure : int;
  avg_duration_ms : float;
}

(* ── Internal state ────────────────────────────────────────────── *)

let mu = Stdlib.Mutex.create ()

(* Global counters, protected by [mu]. *)
let total_events = ref 0
let successful_events = ref 0
let failed_events = ref 0

(* Per-keeper counters, protected by [mu].
   Map keys are keeper names. Each entry is
   {total; success; failure; duration_sum_ms; duration_sample_count}. *)
let per_keeper : (string, int * int * int * float * int) Hashtbl.t =
  Hashtbl.create 16

(* Ring buffer of recent events, protected by [mu].
   LIFO — most recent first. Trimmed to [max_recent_events] on insert. *)
let max_recent_events = 100
let recent_events : telemetry_entry list ref = ref []

(* ── Helpers ───────────────────────────────────────────────────── *)

let with_lock f =
  Stdlib.Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mu) f

(* ── Public API ────────────────────────────────────────────────── *)

let record_event ~keeper_name ~event_kind ~runtime_id ~duration_ms ~success =
  let entry = {
    timestamp = Unix.gettimeofday ();
    keeper_name;
    event_kind;
    runtime_id;
    duration_ms;
    success;
  } in
  with_lock (fun () ->
    (* Update global counters *)
    incr total_events;
    if success then incr successful_events else incr failed_events;

    (* Update per-keeper counters *)
    let t, s, f, d, duration_samples =
      match Hashtbl.find_opt per_keeper keeper_name with
      | Some v -> v
      | None -> (0, 0, 0, 0.0, 0)
    in
    let d', duration_samples' =
      match duration_ms with
      | Some ms -> d +. ms, duration_samples + 1
      | None -> d, duration_samples
    in
    Hashtbl.replace
      per_keeper
      keeper_name
      ((t + 1), (if success then s + 1 else s), (if success then f else f + 1), d', duration_samples');

    (* Append to recent events ring buffer *)
    recent_events := entry :: !recent_events;
    if List.length !recent_events > max_recent_events then
      recent_events := List.take max_recent_events !recent_events
  )

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field names json =
  List.find_map
    (fun name ->
       match assoc_field name json with
       | Some (`String value) when String.trim value <> "" -> Some value
       | Some (`Int value) -> Some (string_of_int value)
       | Some (`Float value) -> Some (string_of_float value)
       | _ -> None)
    names

let float_field names json =
  List.find_map
    (fun name ->
       match assoc_field name json with
       | Some (`Float value) -> Some value
       | Some (`Int value) -> Some (Float.of_int value)
       | Some (`String value) -> Float.of_string_opt (String.trim value)
       | _ -> None)
    names

let success_field json =
  match assoc_field "success" json with
  | Some (`Bool value) -> value
  | _ ->
    (match string_field [ "result"; "outcome"; "status" ] json with
     | Some value ->
       let value = String.lowercase_ascii (String.trim value) in
       not
         (String.equal value "failure"
          || String.equal value "failed"
          || String.equal value "error")
     | None -> true)

let record_telemetry_payload payload =
  let keeper_name =
    string_field [ "keeper_name"; "keeper"; "agent_name"; "agent" ] payload
    |> Option.value ~default:"unknown"
  in
  let event_kind =
    string_field [ "event_kind"; "kind"; "event" ] payload
    |> Option.value ~default:"telemetry_event"
  in
  let runtime_id = string_field [ "runtime_id"; "runtime"; "model_runtime" ] payload in
  let duration_ms = float_field [ "duration_ms"; "elapsed_ms"; "latency_ms" ] payload in
  record_event
    ~keeper_name
    ~event_kind
    ~runtime_id
    ~duration_ms
    ~success:(success_field payload)

let snapshot () =
  with_lock (fun () ->
    let per_keeper_snapshot = Hashtbl.create (Hashtbl.length per_keeper) in
    Hashtbl.iter (fun name (t, s, f, d, duration_samples) ->
      let avg_duration_ms =
        if duration_samples > 0 then d /. Float.of_int duration_samples else 0.0
      in
      Hashtbl.replace per_keeper_snapshot name
        { total = t; success = s; failure = f; avg_duration_ms }
    ) per_keeper;
    {
      total_events = !total_events;
      successful_events = !successful_events;
      failed_events = !failed_events;
      per_keeper = per_keeper_snapshot;
      recent_events = List.rev !recent_events;
    }
  )

let reset () =
  with_lock (fun () ->
    total_events := 0;
    successful_events := 0;
    failed_events := 0;
    Hashtbl.clear per_keeper;
    recent_events := []
  )

let reset_keeper ~keeper_name =
  with_lock (fun () ->
    Hashtbl.remove per_keeper keeper_name
  )
