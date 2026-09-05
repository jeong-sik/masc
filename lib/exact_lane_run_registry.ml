type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention

type outcome =
  | Succeeded
  | Cancelled
  | Failed of
      { code : string
      ; detail : string
      }

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      }
  | Completion_persistence_failed of
      { intended_outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; failure : persistence_failure
      }

type run_input = Exact_input of Yojson.Safe.t

type run =
  { run_id : string
  ; lane : lane
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  }

(* [lane_key] is exhaustive for the wire spelling. [all_lanes] is separately
   pinned to an independent constructor oracle in test_exact_lane_run_registry;
   replay then exercises the exported enumeration. Keep these definitions
   adjacent. *)
let all_lanes = [ Librarian; Hitl_auto_judge; Board_attention ]

let lane_key = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
;;

let lane_of_key = function
  | "librarian_exact" -> Ok Librarian
  | "hitl_auto_judge" -> Ok Hitl_auto_judge
  | "board_attention_exact" -> Ok Board_attention
  | value -> Error (Printf.sprintf "unknown exact lane %S" value)
;;

let outcome_label = function
  | Succeeded -> "succeeded"
  | Cancelled -> "cancelled"
  | Failed _ -> "failed"
;;

let input_to_yojson = function
  | Exact_input payload -> `Assoc [ "kind", `String "exact"; "payload", payload ]
;;

let input_of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = Run_registry_core.Json.object_fields json in
  let* kind = Run_registry_core.Json.string_field "kind" fields in
  match kind with
  | "exact" ->
    let* () = Run_registry_core.Json.exact_fields ~required:[ "kind"; "payload" ] fields in
    let* payload =
      List.assoc_opt "payload" fields |> Option.to_result ~none:"missing field payload"
    in
    Ok (Exact_input payload)
  | value -> Error (Printf.sprintf "unknown exact lane input kind %S" value)
;;

module Payload = struct
  type registration =
    { lane : lane
    ; actor : string
    ; input : run_input
    }

  type completion =
    { outcome : outcome
    ; elapsed_s : float
    ; output : Yojson.Safe.t
    ; selected_slot : string option
    }

  let name = "exact_lane_run_registry"
  let running_noun = "exact lane run(s)"
  let restart_reason = "exact-output fibers do not survive server restart"
  let replayed_running_completion =
    Some
      (fun ~started_at _registration ->
         let elapsed_s = Float.max 0.0 (Time_compat.now () -. started_at) in
         { outcome =
             Failed
               { code = "server_restarted"
               ; detail = restart_reason
               }
         ; elapsed_s
         ; output =
             `Assoc
               [ "reason", `String "server_restarted"
               ; "detail", `String restart_reason
               ]
         ; selected_slot = None
         })
  ;;

  (* Bounded against the surface that reads this, not against the sibling
     registries.

     [`All] was deliberate — #27823 kept every completed run so internal agent
     execution evidence survived. What it did not bound was growth: the live log
     reached 302 MiB across 14 179 rows, and server_runtime_bootstrap.ml:770
     replays all of it on every start, 2 946 ms of read and parse.

     The bound is derived from the consumer rather than copied from
     fusion/verification (which use 64 and have no paging UI).
     [GET /api/v1/dashboard/exact-lane-runs] serves the internal-agents monitor
     with cursor pagination and [exact_lane_run_page_max = 200], so a bound has
     to be a multiple of that page size or the operator's "older" button walks
     off the end of the store. 2 000 is ten full pages at the maximum size, or
     forty at the default of 50, and brings the boot replay to ~416 ms.

     [Run_registry_core.prune] keeps every in-process running entry regardless.
     On replay, the vanished fiber is converted to a durable
     [server_restarted] failure instead of disappearing or remaining Running
     forever. Only terminal runs past the bound are dropped, and replay
     compacts the log to that set on the next clean read. *)
  let completed_retention = `Latest 2000

  (* The bound is per lane: librarian fires every few turns per keeper while
     compaction fires only on a capacity refusal, and under the old global
     bound the busiest lane evicted the quietest — retained_run_count = 0 for
     compaction was indistinguishable from "never ran" (lane audit W8). *)
  let retention_group = Some (fun registration -> lane_key registration.lane)

  let registration_to_yojson registration =
    `Assoc
      [ "lane", `String (lane_key registration.lane)
      ; "actor", `String registration.actor
      ; "input", input_to_yojson registration.input
      ]
  ;;

  let registration_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:[ "lane"; "actor"; "input" ]
        fields
    in
    let* lane_key = Run_registry_core.Json.string_field "lane" fields in
    let* lane = lane_of_key lane_key in
    let* actor = Run_registry_core.Json.string_field "actor" fields in
    let* input =
      match List.assoc_opt "input" fields with
      | Some value -> input_of_yojson value
      | None -> Error "missing field input"
    in
    Ok { lane; actor; input }
  ;;

  let completion_to_yojson completion =
    let detail =
      match completion.outcome with
      | Succeeded | Cancelled -> []
      | Failed { code; detail } ->
        [ "code", `String code; "detail", `String detail ]
    in
    `Assoc
      ([ "outcome", `String (outcome_label completion.outcome)
       ; "elapsed_s", `Float completion.elapsed_s
       ; "output", completion.output
       ; ( "selected_slot"
         , match completion.selected_slot with
           | None -> `Null
           | Some selected_slot -> `String selected_slot )
       ]
       @ detail)
  ;;

  let completion_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* label = Run_registry_core.Json.string_field "outcome" fields in
    let detail_fields =
      match label with
      | "succeeded" | "cancelled" -> Ok []
      | "failed" -> Ok [ "code"; "detail" ]
      | value -> Error (Printf.sprintf "unknown exact lane outcome %S" value)
    in
    let* detail_fields = detail_fields in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:([ "outcome"; "elapsed_s"; "output"; "selected_slot" ] @ detail_fields)
        fields
    in
    let* elapsed_s = Run_registry_core.Json.float_field "elapsed_s" fields in
    let* output =
      match List.assoc_opt "output" fields with
      | Some value -> Ok value
      | None -> Error "missing field output"
    in
    let* outcome =
      match label with
      | "succeeded" -> Ok Succeeded
      | "cancelled" -> Ok Cancelled
      | "failed" ->
        let* code = Run_registry_core.Json.string_field "code" fields in
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Failed { code; detail })
      | value -> Error (Printf.sprintf "unknown exact lane outcome %S" value)
    in
    let* selected_slot =
      match List.assoc_opt "selected_slot" fields with
      | Some `Null -> Ok None
      | Some (`String selected_slot) when String.trim selected_slot <> "" ->
        Ok (Some selected_slot)
      | Some _ -> Error "field selected_slot must be a non-empty string"
      | None -> Error "missing field selected_slot"
    in
    Ok { outcome; elapsed_s; output; selected_slot }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type failed_completion =
  { intended_outcome : outcome
  ; elapsed_s : float
  ; output : Yojson.Safe.t
  ; selected_slot : string option
  ; failure : persistence_failure
  }

type t =
  { store : Store.t
  ; path : string option
  ; failed_completions : (string * failed_completion) list Atomic.t
  ; projection : run list Atomic.t
  ; observation_mutex : Cross_context_mutex.t
  }

type completion_error =
  | Unknown_run
  | Invalid_selected_slot
  | Persistence_failed of persistence_failure

let completion_error_to_string = function
  | Unknown_run -> "completion referenced an unknown exact-lane run"
  | Invalid_selected_slot -> "selected exact-lane slot must be non-blank"
  | Persistence_failed failure -> failure.detail
;;

(* v4 -> v5: #29598 removed [subject_id] from the registration payload. The
   payload decoder is exact-field, so every v4 registration row written before
   that cut is skipped on replay (not refused as a file: [Run_registry_core]
   skips a row it cannot decode, logs the count, and then declines to compact
   a store that has skipped rows). Live on 2026-08-23 that was 2,000 of 4,090
   rows, every completed run gone from the monitor, one 2,000-line WARN per
   boot, and a 36 MB file that can no longer shrink. The removed field rides
   on the store version instead, as #29553 did for the event queue: this
   binary reads only v5 and never opens v4. The rows the cut binary wrote to
   v4 after the field was gone (45 by 11:00Z) are left behind with it.
   [test_store_version_pins_the_registration_shape] holds the row shape and
   this name together. *)
let storage_filename = "exact-lane-runs-v5.jsonl"

(* Re-exported from the store rather than re-derived from [Payload], so the
   bound a test reads is the bound [prune] applies. *)
let max_completed_retained = Store.max_completed_retained
let cut_replay_log = Store.cut_replay_log

let change_observer_fn : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let notify_changed () =
  try (Atomic.get change_observer_fn) () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "exact_lane_run_registry change observer failed: %s"
      (Printexc.to_string exn)
;;

let remove_failed_completion t run_id =
  Atomic.set
    t.failed_completions
    (List.remove_assoc run_id (Atomic.get t.failed_completions))
;;

let projected_run_of_entry failed_completions (entry : Store.entry) =
  let status =
    match List.assoc_opt entry.id failed_completions, entry.status with
    | Some failed, Store.Running ->
      Completion_persistence_failed
        { intended_outcome = failed.intended_outcome
        ; elapsed_s = failed.elapsed_s
        ; output = `Null
        ; selected_slot = failed.selected_slot
        ; failure = failed.failure
        }
    | None, Store.Running -> Running
    | _, Store.Completed completion ->
      Completed
        { outcome = completion.outcome
        ; elapsed_s = completion.elapsed_s
        ; output = `Null
        ; selected_slot = completion.selected_slot
        }
  in
  { run_id = entry.id
  ; lane = entry.registration.lane
  ; actor = entry.registration.actor
  ; started_at = entry.started_at
  ; input = Exact_input `Null
  ; status
  }
;;

let full_run_of_entry failed_completions (entry : Store.entry) =
  let status =
    match List.assoc_opt entry.id failed_completions, entry.status with
    | Some failed, Store.Running ->
      Completion_persistence_failed
        { intended_outcome = failed.intended_outcome
        ; elapsed_s = failed.elapsed_s
        ; output = failed.output
        ; selected_slot = failed.selected_slot
        ; failure = failed.failure
        }
    | None, Store.Running -> Running
    | _, Store.Completed completion ->
      (* A committed completion always wins. This also keeps a stale
         diagnostic overlay from masking durable evidence. *)
      Completed
        { outcome = completion.outcome
        ; elapsed_s = completion.elapsed_s
        ; output = completion.output
        ; selected_slot = completion.selected_slot
        }
  in
  { run_id = entry.id
  ; lane = entry.registration.lane
  ; actor = entry.registration.actor
  ; started_at = entry.started_at
  ; input = entry.registration.input
  ; status
  }
;;

let publish_projection t =
  let failed_completions = Atomic.get t.failed_completions in
  Store.list_entries t.store
  |> List.map (projected_run_of_entry failed_completions)
  |> Atomic.set t.projection
;;

let make ?path store =
  let t =
    { store
    ; path
    ; failed_completions = Atomic.make []
    ; projection = Atomic.make []
    ; observation_mutex = Cross_context_mutex.create ()
    }
  in
  publish_projection t;
  t
;;

let create ?path () = make ?path (Store.create ?path ())
let replay path = make ~path (Store.replay path)

(* [Cross_context_mutex], not [Stdlib.Mutex]: this lock wraps
   [Store.register] / [Store.complete], whose critical section performs a
   durable JSONL append and therefore suspends the fiber. A raw pthread mutex
   held across that suspension is still held by the *same OS thread* when the
   scheduler runs the next fiber on this domain, so that fiber's acquisition
   is recursive and pthreads rejects it with
   [Sys_error "Mutex.lock: Resource deadlock avoided"].

   #28391 fixed the same shape inside [Run_registry_core], which this module
   wraps; the outer lock kept reproducing it. Measured on the live fleet: 231
   occurrences reached this lane through the board attention worker
   ("Board attention worker raised unexpectedly"), which swallows them, plus
   10 through the librarian lane. *)
let register_running t ~run_id ~lane ~actor ~started_at ~input =
  Cross_context_mutex.with_durable_lock t.observation_mutex (fun () ->
    Store.register
      t.store
      ~id:run_id
      ~started_at
      ~registration:{ Payload.lane; actor; input };
    remove_failed_completion t run_id;
    publish_projection t);
  notify_changed ()
;;

let mark_completed_internal t ~run_id ~outcome ~elapsed_s ~selected_slot ~output =
  let completion = { Payload.outcome; elapsed_s; output; selected_slot } in
  let result =
    Cross_context_mutex.with_durable_lock t.observation_mutex (fun () ->
      match Store.complete t.store ~id:run_id ~completion with
      | `Completed ->
        remove_failed_completion t run_id;
        publish_projection t;
        Ok ()
      | `Unknown -> Error Unknown_run
      | `Persistence_failed failure ->
        let state =
          match failure.state with
          | Run_registry_core.Not_persisted -> Not_persisted
          | Run_registry_core.Durability_unknown -> Durability_unknown
        in
        let failure = { detail = failure.detail; state } in
        let failed =
          { intended_outcome = outcome; elapsed_s; output; selected_slot; failure }
        in
        Atomic.set
          t.failed_completions
          ((run_id, failed) :: List.remove_assoc run_id (Atomic.get t.failed_completions));
        publish_projection t;
        Error (Persistence_failed failure))
  in
  match result with
  | Ok () ->
    notify_changed ();
    Ok ()
  | Error Unknown_run -> Error Unknown_run
  | Error Invalid_selected_slot -> Error Invalid_selected_slot
  | Error (Persistence_failed _ as error) ->
    notify_changed ();
    Error error
;;

let mark_completed t ~run_id ~outcome ~elapsed_s ~selected_slot ~output =
  match selected_slot with
  | Some selected_slot when String.trim selected_slot = "" -> Error Invalid_selected_slot
  | None | Some _ ->
    mark_completed_internal t ~run_id ~outcome ~elapsed_s ~selected_slot ~output
;;

(* [total] counts every retained run, not the page, so a caller can say
   "50 of 5,908" without asking for the rest. *)
type run_page =
  { runs : run list
  ; total : int
  ; has_more : bool
  }

let list_runs t = Atomic.get t.projection

(* Newest first, ties broken by run_id, so a page boundary is a total order and
   two runs recorded in the same float second cannot straddle it. *)
let newer_first left right =
  match Float.compare right.started_at left.started_at with
  | 0 -> String.compare right.run_id left.run_id
  | order -> order
;;

let is_older_than ~before run =
  match before with
  | None -> true
  | Some (started_at, run_id) ->
    Float.compare run.started_at started_at < 0
    || (Float.equal run.started_at started_at && String.compare run.run_id run_id < 0)
;;

let recent_runs t ~limit ~before =
  if limit <= 0
  then { runs = []; total = List.length (Atomic.get t.projection); has_more = false }
  else (
    let all = Atomic.get t.projection in
    let candidates = List.filter (is_older_than ~before) all |> List.sort newer_first in
    let rec take taken index = function
      | [] -> List.rev taken, false
      | _ :: _ when index >= limit -> List.rev taken, true
      | run :: rest -> take (run :: taken) (index + 1) rest
    in
    let runs, has_more = take [] 0 candidates in
    { runs; total = List.length all; has_more })
;;

let parse_disk_event_line line =
  try
    let json = Yojson.Safe.from_string line in
    match json with
    | `Assoc fields ->
      let event = List.assoc_opt "event" fields in
      let id = List.assoc_opt "id" fields in
      (match event, id with
       | Some (`String "register"), Some (`String id) ->
         let started_at =
           match List.assoc_opt "started_at" fields with
           | Some (`Float f) -> f
           | Some (`Int i) -> float_of_int i
           | _ -> 0.0
         in
         (match List.assoc_opt "registration" fields with
          | Some reg_json ->
            (match Payload.registration_of_yojson reg_json with
             | Ok reg -> Some (`Register (id, started_at, reg))
             | Error _ -> None)
          | None -> None)
       | Some (`String "complete"), Some (`String id) ->
         (match List.assoc_opt "completion" fields with
          | Some comp_json ->
            (match Payload.completion_of_yojson comp_json with
             | Ok comp -> Some (`Complete (id, comp))
             | Error _ -> None)
          | None -> None)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;

let load_run_from_disk ~path ~run_id =
  if not (Fs_compat.file_exists path)
  then None
  else (
    let id_pattern = Printf.sprintf "\"id\":\"%s\"" run_id in
    let id_pattern_spaced = Printf.sprintf "\"id\": \"%s\"" run_id in
    let register_event = ref None in
    let complete_event = ref None in
    let matches_id line =
      String_util.contains_substring line id_pattern
      || String_util.contains_substring line id_pattern_spaced
    in
    try
      let _boundary =
        Fs_compat.fold_appended_lines
          ~path
          ~from:0
          ~init:()
          ~f:(fun () line ->
            if matches_id line
            then (
              match parse_disk_event_line line with
              | Some (`Register (id, started_at, reg)) when String.equal id run_id ->
                register_event := Some (started_at, reg)
              | Some (`Complete (id, comp)) when String.equal id run_id ->
                complete_event := Some comp
              | _ -> ()))
      in
      match !register_event with
      | None -> None
      | Some (started_at, registration) ->
        let status =
          match !complete_event with
          | None -> Running
          | Some completion ->
            Completed
              { outcome = completion.outcome
              ; elapsed_s = completion.elapsed_s
              ; output = completion.output
              ; selected_slot = completion.selected_slot
              }
        in
        Some
          { run_id
          ; lane = registration.lane
          ; actor = registration.actor
          ; started_at
          ; input = registration.input
          ; status
          }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Keeper.warn
        "exact_lane_run_registry: disk load error for %s: %s"
        run_id
        (Printexc.to_string exn);
      None)
;;

let get t ~run_id =
  let from_disk =
    match t.path with
    | Some path -> load_run_from_disk ~path ~run_id
    | None -> None
  in
  let failed_completions = Atomic.get t.failed_completions in
  let overlay_failed run =
    match List.assoc_opt run.run_id failed_completions with
    | Some failed when run.status = Running ->
      { run with
        status =
          Completion_persistence_failed
            { intended_outcome = failed.intended_outcome
            ; elapsed_s = failed.elapsed_s
            ; output = failed.output
            ; selected_slot = failed.selected_slot
            ; failure = failed.failure
            }
      }
    | _ -> run
  in
  match from_disk with
  | Some run -> Some (overlay_failed run)
  | None ->
    (match Store.get t.store ~id:run_id with
     | Some entry -> Some (full_run_of_entry failed_completions entry)
     | None -> None)
;;

let status_label = function
  | Running -> "running"
  | Completed { outcome; _ } -> outcome_label outcome
  | Completion_persistence_failed { failure = { state = Not_persisted; _ }; _ } ->
    "completion_persistence_failed"
  | Completion_persistence_failed
      { failure = { state = Durability_unknown; _ }; _ } ->
    "completion_durability_unknown"
;;

(* Identity and outcome of a run, without either exact payload. A lane run
   embeds the captured template and actual input material that reconstructs
   the rendered prompt — on this host one field,
   [rendered_prompt_variables.conversation_history], was 136.6 MB of a 286 MB
   store — so a list that carried payloads shipped hundreds of megabytes to
   draw a table of timestamps. The payloads live behind {!run_to_yojson}, which
   the detail route serves for one run at a time. *)
let run_summary_fields run =
  let base =
    [ "run_id", `String run.run_id
    ; "lane", `String (lane_key run.lane)
    ; ( "subject_id"
      , `Null
        (* This registry has no generic subject identity. Keep absence explicit
           instead of deriving one from a lane-specific payload. *) )
    ; "actor", `String run.actor
    ; "started_at", `Float run.started_at
    ; "status", `String (status_label run.status)
    ]
  in
  let completion =
    match run.status with
    | Running -> []
    | Completed { outcome; elapsed_s; output = _; selected_slot } ->
      let detail =
        match outcome with
        | Succeeded | Cancelled -> []
        | Failed { code; detail } ->
          [ "code", `String code; "detail", `String detail ]
      in
      [ "elapsed_s", `Float elapsed_s
      ; ( "selected_slot"
        , match selected_slot with
          | None -> `Null
          | Some selected_slot -> `String selected_slot )
      ]
      @ detail
    | Completion_persistence_failed
        { intended_outcome; elapsed_s; output = _; selected_slot; failure } ->
      let intended_failure =
        match intended_outcome with
        | Succeeded | Cancelled -> []
        | Failed { code; detail } ->
          [ "intended_code", `String code; "intended_detail", `String detail ]
      in
      [ "intended_status", `String (outcome_label intended_outcome)
      ; "elapsed_s", `Float elapsed_s
      ; ( "selected_slot"
        , match selected_slot with
          | None -> `Null
          | Some selected_slot -> `String selected_slot )
      ; "persistence_error", `String failure.detail
      ; ( "persistence_state"
        , `String
            (match failure.state with
             | Not_persisted -> "not_persisted"
             | Durability_unknown -> "durability_unknown") )
      ]
      @ intended_failure
  in
  base @ completion
;;

let run_summary_to_yojson run = `Assoc (run_summary_fields run)

(* The whole record, exact payloads included. Served one run at a time by the
   detail route; a list never carries these. *)
let run_to_yojson run =
  let output_field =
    match run.status with
    | Running -> []
    | Completed { output; _ } | Completion_persistence_failed { output; _ } ->
      [ "output", output ]
  in
  `Assoc ((run_summary_fields run @ [ "input", input_to_yojson run.input ]) @ output_field)
;;

type global_install_error = Already_installed

module Global = Run_registry_core.Global (struct
    type nonrec t = t

    let initial = create ()
  end)

let global = Global.current

let install_global registry =
  match Global.install registry with
  | Ok () -> Ok ()
  | Error Global.Already_installed -> Error Already_installed
;;
