type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Candle_appraiser

let run_lane = function
  | Librarian -> Lane_run_identity.Librarian
  | Hitl_auto_judge -> Lane_run_identity.Hitl_auto_judge
  | Board_attention -> Lane_run_identity.Board_attention
  | Workspace_curator -> Lane_run_identity.Workspace_curator
  | Candle_appraiser -> Lane_run_identity.Candle_appraiser
;;

let lane_of_run_lane = function
  | Lane_run_identity.Librarian -> Some Librarian
  | Lane_run_identity.Hitl_auto_judge -> Some Hitl_auto_judge
  | Lane_run_identity.Board_attention -> Some Board_attention
  | Lane_run_identity.Workspace_curator -> Some Workspace_curator
  | Lane_run_identity.Candle_appraiser -> Some Candle_appraiser
  | Lane_run_identity.Verifier | Lane_run_identity.Browser_stagehand -> None
;;

let lane_of_standalone lane = lane_of_run_lane (Standalone_lane.run_identity lane)
let lane_id lane = Lane_run_identity.to_id (run_lane lane)

type outcome =
  | Succeeded
  | Cancelled
  | Failed of
      { code : string
      ; detail : string
      }

let server_restarted_code = "server_restarted"

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }

let usage_of_api_usage (api_usage : Agent_core.Types.api_usage) =
  { input_tokens = api_usage.input_tokens
  ; output_tokens = api_usage.output_tokens
  ; cache_creation_input_tokens = api_usage.cache_creation_input_tokens
  ; cache_read_input_tokens = api_usage.cache_read_input_tokens
  ; cost_usd = api_usage.cost_usd
  ;}
;;

type completion_origin = Producer | Restart_replay

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; origin : completion_origin
      ; elapsed_s : float option
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; usage : usage option
      }
  | Completion_persistence_failed of
      { intended_outcome : outcome
      ; elapsed_s : float option
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; usage : usage option
      ; failure : persistence_failure
      }

type run_input = Exact_input of Yojson.Safe.t

type payload_read_error =
  | Source_unavailable of string
  | Missing_registration
  | Missing_completion
  | Invalid_payload of string
  | Snapshot_changed

type payload_availability =
  | Available
  | Not_loaded
  | Unavailable of payload_read_error

let payload_read_error_to_string = function
  | Source_unavailable detail -> detail
  | Missing_registration -> "The retained run's registration payload is missing"
  | Missing_completion -> "The retained run's completion payload is missing"
  | Invalid_payload detail -> detail
  | Snapshot_changed -> "The selected run changed while its payload was being read"
;;

let availability_to_yojson = function
  | Available -> `Assoc [ "state", `String "available" ]
  | Not_loaded -> `Assoc [ "state", `String "not_loaded" ]
  | Unavailable error ->
    let code, extra =
      match error with
      | Source_unavailable _ -> "source_unavailable", []
      | Missing_registration -> "missing_registration", []
      | Missing_completion -> "missing_completion", []
      | Invalid_payload _ -> "invalid_payload", []
      | Snapshot_changed -> "snapshot_changed", []
    in
    `Assoc
      [ "state", `String "unavailable"
      ; "error", `Assoc
          ([ "code", `String code
           ; "message", `String (payload_read_error_to_string error) ] @ extra)
      ]
;;

let availability_of_yojson json =
  let ( let* ) = Result.bind in
  let module Json = Run_registry_core.Json in
  let* fields = Json.object_fields json in
  let* state = Json.string_field "state" fields in
  let state_only availability =
    let* () = Json.exact_fields ~required:[ "state" ] fields in
    Ok availability
  in
  match state with
  | "available" -> state_only Available
  | "not_loaded" -> state_only Not_loaded
  | "unavailable" ->
    let* () = Json.exact_fields ~required:[ "state"; "error" ] fields in
    let* error = List.assoc_opt "error" fields |> Option.to_result ~none:"missing error" in
    let* fields = Json.object_fields error in
    let* code = Json.string_field "code" fields in
    let* message = Json.string_field "message" fields in
    let message_only error =
      let* () = Json.exact_fields ~required:[ "code"; "message" ] fields in
      Ok error
    in
    let* error =
      match code with
      | "source_unavailable" -> message_only (Source_unavailable message)
      | "missing_registration" -> message_only Missing_registration
      | "missing_completion" -> message_only Missing_completion
      | "invalid_payload" -> message_only (Invalid_payload message)
      | "snapshot_changed" -> message_only Snapshot_changed
      | _ -> Error (Printf.sprintf "unknown payload error code %S" code)
    in
    Ok (Unavailable error)
  | _ -> Error (Printf.sprintf "unknown payload availability %S" state)
;;

let usage_to_yojson usage =
  let fields =
    [ "input_tokens", `Int usage.input_tokens
    ; "output_tokens", `Int usage.output_tokens
    ; "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
    ]
  in
  `Assoc
    (match usage.cost_usd with
     | None -> fields
     | Some cost_usd -> fields @ [ "cost_usd", `Float cost_usd ])
;;

let usage_of_yojson json =
  let ( let* ) = Result.bind in
  let module Json = Run_registry_core.Json in
  let* fields = Json.object_fields json in
  let* () =
    Json.exact_fields
      ~required:[ "input_tokens"; "output_tokens"; "cache_creation_input_tokens"; "cache_read_input_tokens" ]
      ~optional:[ "cost_usd" ]
      fields
  in
  let int_field name =
    match List.assoc_opt name fields with
    | Some (`Int value) when value >= 0 -> Ok value
    | Some _ | None -> Error (Printf.sprintf "field %s must be a non-negative integer" name)
  in
  let* input_tokens = int_field "input_tokens" in
  let* output_tokens = int_field "output_tokens" in
  let* cache_creation_input_tokens = int_field "cache_creation_input_tokens" in
  let* cache_read_input_tokens = int_field "cache_read_input_tokens" in
  let* cost_usd =
    match List.assoc_opt "cost_usd" fields with
    | None -> Ok None
    | Some (`Float cost_usd) when Float.is_finite cost_usd && cost_usd >= 0. -> Ok (Some cost_usd)
    | Some (`Int cost_usd) when cost_usd >= 0 -> Ok (Some (float_of_int cost_usd))
    | Some _ -> Error "field cost_usd must be a non-negative finite float"
  in
  Ok { input_tokens; output_tokens; cache_creation_input_tokens; cache_read_input_tokens; cost_usd }
;;

type run =
  { run_id : string
  ; lane : lane
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  ; input_availability : payload_availability
  ; output_availability : payload_availability option
  }

let lane_of_key key =
  match Lane_run_identity.of_id key with
  | None -> Error (Printf.sprintf "unknown exact lane %S" key)
  | Some standalone ->
    (match lane_of_run_lane standalone with
     | Some lane -> Ok lane
     | None ->
       Error
         (Printf.sprintf "exact lane %S has no run records in this registry" key))
;;

let outcome_label = function
  | Succeeded -> "succeeded"
  | Cancelled -> "cancelled"
  | Failed _ -> "failed"
;;

let input_to_yojson = function
  | Exact_input payload -> `Assoc [ "kind", `String "exact"; "payload", payload ]
;;

(* Where a run's input or output value is kept. The prompt and the response
   are most of this registry's bytes (2026-09-15: 12,407 rows, 781.7 MB, row
   p90 152,676 B), so a disk-backed store writes each one to the run's payload
   file and the log row records its size and SHA-256. [In_row] is a value the
   row carries itself: the verdict replay writes for a run that did not survive
   a restart, and every value of a store with no path. *)
type payload_source =
  | In_file of
      { bytes : int
      ; sha256 : string
      }
  | In_row

let payload_source_to_yojson ~value source =
  match source with
  | In_file { bytes; sha256 } ->
    `Assoc [ "kind", `String "file"; "bytes", `Int bytes; "sha256", `String sha256 ]
  | In_row -> `Assoc [ "kind", `String "row"; "value", value ]
;;

let payload_source_of_yojson json =
  let ( let* ) = Result.bind in
  let module Json = Run_registry_core.Json in
  let* fields = Json.object_fields json in
  let* kind = Json.string_field "kind" fields in
  match kind with
  | "file" ->
    let* () = Json.exact_fields ~required:[ "kind"; "bytes"; "sha256" ] fields in
    let* sha256 = Json.string_field "sha256" fields in
    (match List.assoc_opt "bytes" fields with
     | Some (`Int bytes) when bytes >= 0 -> Ok (In_file { bytes; sha256 }, `Null)
     | Some _ | None -> Error "payload bytes must be a non-negative integer")
  | "row" ->
    let* () = Json.exact_fields ~required:[ "kind"; "value" ] fields in
    let* value = List.assoc_opt "value" fields |> Option.to_result ~none:"missing field value" in
    Ok (In_row, value)
  | value -> Error (Printf.sprintf "unknown payload source kind %S" value)
;;

module Payload = struct
  type registration =
    { lane : lane
    ; actor : string
    ; input : run_input
    ; input_source : payload_source
    }

  type completion =
    { outcome : outcome
    ; origin : completion_origin
    ; elapsed_s : float option
    ; output : Yojson.Safe.t
    ; output_source : payload_source
    ; selected_slot : string option
    ; usage : usage option
    }

  let name = "exact_lane_run_registry"
  let running_noun = "exact lane run(s)"
  let restart_reason = "exact-output fibers do not survive server restart"
  let replayed_running_completion =
    Some
      (fun ~started_at:_ _registration ->
         { outcome =
             Failed
               { code = server_restarted_code
               ; detail = restart_reason
               }
         ; origin = Restart_replay
         ; elapsed_s = None
         ; output =
             `Assoc
               [ "reason", `String server_restarted_code
               ; "detail", `String restart_reason
               ]
         ; output_source = In_row
         ; selected_slot = None
         ; usage = None
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
     forty at the default of 50.

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
  let retention_group = Some (fun registration -> lane_id registration.lane)

  (* A value kept in a payload file is dropped from the copy the store keeps.
     The list projection reads none of it -- [projected_run_of_entry] sets both
     to [`Null] -- and the detail route reads the file of the one run it
     serves. What stays is what a projection reads (lane, actor, outcome) and
     the size and digest the detail read checks the file against. An [In_row]
     value has no other source and stays. *)
  let shed_registration registration =
    match registration.input_source with
    | In_file _ -> { registration with input = Exact_input `Null }
    | In_row -> registration
  ;;

  let shed_completion (completion : completion) =
    match completion.output_source with
    | In_file _ -> { completion with output = `Null }
    | In_row -> completion
  ;;

  let registration_to_yojson registration =
    `Assoc
      [ "lane", `String (lane_id registration.lane)
      ; "actor", `String registration.actor
      ; ( "input"
        , match registration.input with
          | Exact_input value ->
            payload_source_to_yojson ~value registration.input_source )
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
    let* input_source, value =
      match List.assoc_opt "input" fields with
      | Some value -> payload_source_of_yojson value
      | None -> Error "missing field input"
    in
    Ok { lane; actor; input = Exact_input value; input_source }
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
       ; "origin", `String (match completion.origin with Producer -> "producer" | Restart_replay -> "restart_replay")
       ; "elapsed_s", (match completion.elapsed_s with None -> `Null | Some value -> `Float value)
       ; "output", payload_source_to_yojson ~value:completion.output completion.output_source
       ; ( "selected_slot"
         , match completion.selected_slot with
           | None -> `Null
           | Some selected_slot -> `String selected_slot )
       ; ( "usage"
         , match completion.usage with
           | None -> `Null
           | Some usage -> usage_to_yojson usage )
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
        ~required:([ "outcome"; "origin"; "elapsed_s"; "output"; "selected_slot"; "usage" ] @ detail_fields)
        fields
    in
    let* origin = match List.assoc_opt "origin" fields with
      | Some (`String "producer") -> Ok Producer
      | Some (`String "restart_replay") -> Ok Restart_replay
      | Some _ | None -> Error "completion origin is absent or unknown" in
    let* elapsed_s = match List.assoc_opt "elapsed_s" fields with
      | Some `Null -> Ok None
      | Some (`Float value) when Float.is_finite value && value >= 0. -> Ok (Some value)
      | Some (`Int value) when value >= 0 -> Ok (Some (float_of_int value))
      | Some _ | None -> Error "elapsed_s must be null or a nonnegative finite duration" in
    let* () = match origin,elapsed_s with
      | Restart_replay,Some _ -> Error "restart observation cannot carry a measured duration"
      | Restart_replay,None | Producer,(None|Some _) -> Ok () in
    let* output_source, output =
      match List.assoc_opt "output" fields with
      | Some value -> payload_source_of_yojson value
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
    let* usage =
      match List.assoc_opt "usage" fields with
      | Some `Null -> Ok None
      | None -> Error "missing field usage"
      | Some json ->
        (match usage_of_yojson json with
         | Ok usage -> Ok (Some usage)
         | Error detail -> Error (Printf.sprintf "field usage: %s" detail))
    in
    let* () = match origin with
      | Producer -> Ok ()
      | Restart_replay ->
        let valid_outcome = match outcome with
          | Failed {code;detail} -> code=server_restarted_code && detail=restart_reason
          | Succeeded | Cancelled -> false in
        let inline = match output_source with In_row -> true | In_file _ -> false in
        let expected=`Assoc ["reason",`String server_restarted_code;"detail",`String restart_reason] in
        if valid_outcome && inline && selected_slot=None && usage=None
           && Yojson.Safe.equal (Yojson.Safe.sort output) (Yojson.Safe.sort expected) then Ok ()
        else Error "restart completion does not match the original replay observation" in
    Ok { outcome; origin; elapsed_s; output; output_source; selected_slot; usage }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type failed_completion =
  { intended_outcome : outcome
  ; elapsed_s : float option
  ; output : Yojson.Safe.t
  ; selected_slot : string option
  ; usage : usage option
  ; failure : persistence_failure
  }

type payload_sweep_counts =
  { examined_root_entries : int
  ; unlinked_entries : int
  ; removed_run_directories : int
  ; failed_root_entries : int
  }

type payload_sweep_status =
  | Not_attempted
  | Replay_not_trusted
  | Root_absent
  | Root_unavailable
  | Swept of payload_sweep_counts

type startup_observation =
  { replay : Run_registry_core.replay_status
  ; payload_sweep : payload_sweep_status
  }

type t =
  { store : Store.t
  ; path : string option
  ; failed_completions : (string * failed_completion) list Atomic.t
  ; projection : run list Atomic.t
  ; observation_mutex : Cross_context_mutex.t
  ; startup_observation : startup_observation
  }

type completion_error =
  | Unknown_run
  | Invalid_selected_slot
  | Invalid_elapsed_duration
  | Persistence_failed of persistence_failure

let completion_error_to_string = function
  | Unknown_run -> "completion referenced an unknown exact-lane run"
  | Invalid_selected_slot -> "selected exact-lane slot must be non-blank"
  | Invalid_elapsed_duration -> "measured exact-lane duration must be nonnegative and finite"
  | Persistence_failed failure -> failure.detail
;;

(* The row shape is tied to this name: a row records where its input and
   output are kept ([payload_source]) rather than the values, and this binary
   reads only this generation. [test_store_version_pins_the_registration_shape]
   holds the row shape and this name together. *)
let storage_filename = "exact-lane-runs-v7.jsonl"

(* Next to the log: [<dir>/exact-lane-run-payloads-v7/<run_id>/input-<sha256>.json]
   and [output-<sha256>.json]. The digest is part of the name, so writing a new
   value for a run never replaces the bytes a durable row already names: a
   second registration of one id whose append then fails leaves the first
   registration's file as it was. *)
let payload_dirname = "exact-lane-run-payloads-v7"

type payload_kind =
  | Input_payload
  | Output_payload

let payload_leaf kind ~sha256 =
  match kind with
  | Input_payload -> Printf.sprintf "input-%s.json" sha256
  | Output_payload -> Printf.sprintf "output-%s.json" sha256
;;

(* A run id names a directory. Producers mint them with [Random_id.prefixed];
   an id that is not one plain path segment could escape the payload
   directory, so it is refused before anything is written. *)
let run_id_is_a_segment run_id =
  (not (String.equal run_id ""))
  && (not (String.equal run_id "."))
  && (not (String.equal run_id ".."))
  && not (String.exists (fun c -> Char.equal c '/' || Char.equal c '\\' || Char.equal c '\000') run_id)
;;

let payload_run_dir ~log_path ~run_id =
  Filename.concat (Filename.concat (Filename.dirname log_path) payload_dirname) run_id
;;

let payload_path ~log_path ~run_id kind ~sha256 =
  Filename.concat (payload_run_dir ~log_path ~run_id) (payload_leaf kind ~sha256)
;;

(* Written before the row that points at it, so a durable row always names a
   file that exists. A row whose append then fails leaves the file behind for
   the replay sweep. *)
let write_payload ~log_path ~run_id kind value =
  let text = Yojson.Safe.to_string value in
  let sha256 = Digestif.SHA256.(digest_string text |> to_hex) in
  match
    Keeper_fs.save_bytes_durable_atomic (payload_path ~log_path ~run_id kind ~sha256) text
  with
  | Ok () -> Ok (In_file { bytes = String.length text; sha256 })
  | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
;;

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
        ; usage = failed.usage
        ; failure = failed.failure
        }
    | None, Store.Running -> Running
    | _, Store.Completed completion ->
      Completed
        { outcome = completion.outcome
        ; origin = completion.origin
        ; elapsed_s = completion.elapsed_s
        ; output = `Null
        ; selected_slot = completion.selected_slot
        ; usage = completion.usage
        }
  in
  { run_id = entry.id
  ; lane = entry.registration.lane
  ; actor = entry.registration.actor
  ; started_at = entry.started_at
  ; input = Exact_input `Null
  ; status
  ; input_availability = Not_loaded
  ; output_availability =
      (match status with Running -> None | Completed _ | Completion_persistence_failed _ -> Some Not_loaded)
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
        ; usage = failed.usage
        ; failure = failed.failure
        }
    | None, Store.Running -> Running
    | _, Store.Completed completion ->
      (* A committed completion always wins. This also keeps a stale
         diagnostic overlay from masking durable evidence. *)
      Completed
        { outcome = completion.outcome
        ; origin = completion.origin
        ; elapsed_s = completion.elapsed_s
        ; output = completion.output
        ; selected_slot = completion.selected_slot
        ; usage = completion.usage
        }
  in
  { run_id = entry.id
  ; lane = entry.registration.lane
  ; actor = entry.registration.actor
  ; started_at = entry.started_at
  ; input = entry.registration.input
  ; status
  ; input_availability = Available
  ; output_availability =
      (match status with Running -> None | Completed _ | Completion_persistence_failed _ -> Some Available)
  }
;;

module String_set = Set.Make (String)

(* A run's payload files leave with the run: when retention evicts it from the
   store, or when a replay that read the whole log finds a directory no
   retained row names. Every entry of the directory goes, including a temporary
   file a crashed write left behind. A removal that fails is logged and the
   directory stays; nothing reads it. *)
let remove_files_in ~dir ~keep ~on_unlink =
  Array.iter
    (fun name ->
       if not (String_set.mem name keep)
       then (
         Sys.remove (Filename.concat dir name);
         on_unlink ()))
    (Sys.readdir dir)
;;

let remove_payload_dir ~log_path ~run_id ~on_unlink ~on_directory_removed =
  let dir = payload_run_dir ~log_path ~run_id in
  try
    Eio_guard.run_in_systhread ~label:"exact-lane-payload-remove" (fun () ->
      match Unix.stat dir with
      | _ ->
        remove_files_in ~dir ~keep:String_set.empty ~on_unlink;
        Unix.rmdir dir;
        on_directory_removed ()
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    Keeper_fs.invalidate_dir dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Keeper.warn
      "exact_lane_run_registry: could not remove payload files of %s: %s"
      run_id
      (Printexc.to_string exn);
    Error ()
;;

let publish_projection t =
  let failed_completions = Atomic.get t.failed_completions in
  let previous = Atomic.get t.projection in
  let next =
    Store.list_entries t.store |> List.map (projected_run_of_entry failed_completions)
  in
  Atomic.set t.projection next;
  match t.path with
  | None -> ()
  | Some log_path ->
    let retained = String_set.of_list (List.map (fun run -> run.run_id) next) in
    List.iter
      (fun run ->
         if not (String_set.mem run.run_id retained)
         then
           ignore
             (remove_payload_dir ~log_path ~run_id:run.run_id
                ~on_unlink:(fun () -> ()) ~on_directory_removed:(fun () -> ())))
      previous
;;

let referenced_leaves (entry : Store.entry) =
  let leaf kind = function
    | In_file { sha256; _ } -> [ payload_leaf kind ~sha256 ]
    | In_row -> []
  in
  let output =
    match entry.status with
    | Store.Running -> []
    | Store.Completed completion -> leaf Output_payload completion.output_source
  in
  String_set.of_list (leaf Input_payload entry.registration.input_source @ output)
;;

(* Only after a replay that read every row and refused none: a replay whose
   read failed or stopped at a torn tail publishes fewer runs than the log
   holds, and sweeping against that would delete payloads the log still
   names. *)
let sweep_payload_dirs t ~log_path =
  let root = Filename.concat (Filename.dirname log_path) payload_dirname in
  let sweep names =
    let referenced = Hashtbl.create 1024 in
    List.iter
      (fun (entry : Store.entry) -> Hashtbl.replace referenced entry.id (referenced_leaves entry))
      (Store.list_entries t.store);
    (* These counters belong only to this synchronous startup sweep. Increment
       after each successful effect, inside its joined systhread, so a later
       failure cannot erase earlier successful removals. *)
    let unlinked_entries = ref 0 in
    let removed_run_directories = ref 0 in
    let failed_root_entries = ref 0 in
    let on_unlink () = incr unlinked_entries in
    let on_directory_removed () = incr removed_run_directories in
    let sweep_entry name =
      let path = Filename.concat root name in
      match Hashtbl.find_opt referenced name, Sys.is_directory path with
      | None, true ->
        remove_payload_dir ~log_path ~run_id:name ~on_unlink ~on_directory_removed
      | Some keep, true ->
        (* A retained run keeps the files its row names; a superseded
           registration of the same id and a torn temporary file go. *)
        Eio_guard.run_in_systhread ~label:"exact-lane-payload-remove" (fun () ->
          remove_files_in ~dir:path ~keep ~on_unlink);
        Ok ()
      | (None | Some _), false ->
        Sys.remove path;
        on_unlink ();
        Ok ()
    in
    Array.iter
      (fun name ->
         match sweep_entry name with
         | Ok () -> ()
         | Error () -> incr failed_root_entries
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception ((Sys_error _ | Unix.Unix_error _) as exn) ->
           incr failed_root_entries;
           Log.Keeper.warn
             "exact_lane_run_registry: could not sweep payload entry %s under %s: %s"
             name
             root
             (Printexc.to_string exn))
      names;
    Swept
      { examined_root_entries = Array.length names
      ; unlinked_entries = !unlinked_entries
      ; removed_run_directories = !removed_run_directories
      ; failed_root_entries = !failed_root_entries
      }
  in
  match Store.replay_status t.store with
  | Run_registry_core.Replayed { reached_end = true; malformed_lines = 0; _ } ->
    (* [Sys.file_exists] hides permission errors as false. Distinguish actual
       absence from an unavailable root without inventing a cleanup policy. *)
    (match
       Eio_guard.run_in_systhread ~label:"exact-lane-payload-list" (fun () ->
         match Unix.stat root with
         | _ -> Some (Sys.readdir root)
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None)
     with
     | None -> Root_absent
     | Some names -> sweep names
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Sys_error _ | Unix.Unix_error _) as exn) ->
       Log.Keeper.warn
         "exact_lane_run_registry: could not list payload entries under %s: %s"
         root
         (Printexc.to_string exn);
       Root_unavailable)
  | Run_registry_core.Replayed _ | Run_registry_core.Log_absent | Run_registry_core.Not_replayed
    -> Replay_not_trusted
;;

let make ?path store =
  let t =
    { store
    ; path
    ; failed_completions = Atomic.make []
    ; projection = Atomic.make []
    ; observation_mutex = Cross_context_mutex.create ()
    ; startup_observation =
        { replay = Store.replay_status store; payload_sweep = Not_attempted }
    }
  in
  publish_projection t;
  t
;;

let create ?path () = make ?path (Store.create ?path ())
let replay path =
  let t = make ~path (Store.replay path) in
  let payload_sweep = sweep_payload_dirs t ~log_path:path in
  { t with startup_observation = { t.startup_observation with payload_sweep } }
;;

let startup_observation t = t.startup_observation

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
  if not (run_id_is_a_segment run_id)
  then invalid_arg (Printf.sprintf "exact lane run id %S is not a path segment" run_id);
  (* Outside the lock: the file name carries its digest, so this write shares
     nothing with another run's or with this run's earlier files. *)
  let input_source =
    match t.path, input with
    | None, Exact_input _ -> In_row
    | Some log_path, Exact_input value ->
      (match write_payload ~log_path ~run_id Input_payload value with
       | Ok source -> source
       | Error detail -> raise (Sys_error detail))
  in
  Cross_context_mutex.with_durable_lock t.observation_mutex (fun () ->
    Store.register
      t.store
      ~id:run_id
      ~started_at
      ~registration:{ Payload.lane; actor; input; input_source };
    remove_failed_completion t run_id;
    publish_projection t);
  notify_changed ()
;;

let mark_completed_internal t ~run_id ~outcome ~elapsed_s ~selected_slot ~usage ~output =
  (* Outside the lock, as in [register_running]. A run that stops being known
     before the lock is taken leaves this file for the replay sweep. *)
  let stored =
    match t.path with
    | None -> Ok In_row
    | Some log_path ->
      (match Store.get_metadata t.store ~id:run_id with
       | None -> Error `Unknown
       | Some _ ->
         (match write_payload ~log_path ~run_id Output_payload output with
          | Ok source -> Ok source
          | Error detail ->
            Error
              (`Persistence_failed
                { Run_registry_core.detail; state = Run_registry_core.Not_persisted })))
  in
  let result =
    Cross_context_mutex.with_durable_lock t.observation_mutex (fun () ->
      let completed =
        match stored with
        | Error _ as error -> error
        | Ok output_source ->
          let completion = { Payload.outcome; origin=Producer; elapsed_s; output; output_source; selected_slot; usage } in
          (match Store.complete t.store ~id:run_id ~completion with
           | `Completed -> Ok ()
           | (`Unknown | `Persistence_failed _) as error -> Error error)
      in
      match completed with
      | Ok () ->
        remove_failed_completion t run_id;
        publish_projection t;
        Ok ()
      | Error `Unknown -> Error Unknown_run
      | Error (`Persistence_failed (failure : Run_registry_core.persistence_failure)) ->
        let state =
          match failure.state with
          | Run_registry_core.Not_persisted -> Not_persisted
          | Run_registry_core.Durability_unknown -> Durability_unknown
        in
        let failure = { detail = failure.detail; state } in
        let failed =
          { intended_outcome = outcome; elapsed_s; output; selected_slot; usage; failure }
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
  | Error Invalid_elapsed_duration -> Error Invalid_elapsed_duration
  | Error (Persistence_failed _ as error) ->
    notify_changed ();
    Error error
;;

let mark_completed t ~run_id ~outcome ~elapsed_s ~selected_slot ?usage ~output () =
  if not (Float.is_finite elapsed_s) || elapsed_s < 0. then Error Invalid_elapsed_duration else
  match selected_slot with
  | Some selected_slot when String.trim selected_slot = "" -> Error Invalid_selected_slot
  | None | Some _ ->
    mark_completed_internal t ~run_id ~outcome ~elapsed_s:(Some elapsed_s) ~selected_slot ~usage ~output
;;

let mark_completed_unmeasured t ~run_id ~outcome ~selected_slot ?usage ~output () =
  match selected_slot with
  | Some selected_slot when String.trim selected_slot = "" -> Error Invalid_selected_slot
  | None | Some _ ->
    mark_completed_internal t ~run_id ~outcome ~elapsed_s:None ~selected_slot ~usage ~output
;;

(* [total] counts every retained run, not the page, so a caller can say
   "50 of 5,908" without asking for the rest. *)
type run_page =
  { runs : run list
  ; total : int
  ; has_more : bool
  }

type original_completion = {
  outcome:outcome; elapsed_s:float option; output:Yojson.Safe.t;
  selected_slot:string option; usage:usage option;
}
type reconciliation_error =
  | Invalid_original of string
  | Original_registration_conflict
  | Original_completion_conflict
  | Failed_completion_conflict
  | Reconciliation_unavailable of string
  | Reconciliation_persistence_failed of persistence_failure
let reconciliation_error_to_string = function
  | Invalid_original detail | Reconciliation_unavailable detail -> detail
  | Original_registration_conflict -> "The original exact registration conflicts with current history"
  | Original_completion_conflict -> "A genuine producer terminal conflicts with the original receipt"
  | Failed_completion_conflict -> "A different failed completion remains unresolved"
  | Reconciliation_persistence_failed failure -> failure.detail

(* This validation is independent of any Addon/domain codec. The registry must
   not publish nonstandard numbers or duplicate object keys from any caller. *)
let rec validate_original_json = function
  | `Assoc fields ->
    let ( let* )=Result.bind in
    let* ()=Run_registry_core.Json.exact_fields ~required:(List.map fst fields) fields in
    List.fold_left (fun result (_,value) -> let* ()=result in validate_original_json value) (Ok ()) fields
  | `List values ->
    List.fold_left (fun result value -> Result.bind result (fun () -> validate_original_json value)) (Ok ()) values
  | `Float value when not (Float.is_finite value) -> Error "Original JSON contains a non-finite number"
  | `Intlit value ->
    (try match Yojson.Safe.from_string value with
     | `Int _ | `Intlit _ -> Ok ()
     | `Null | `Bool _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error "Invalid original JSON integer"
     with Yojson.Json_error detail -> Error detail)
  | `Null | `Bool _ | `Int _ | `Float _ | `String _ -> Ok ()
let original_json_equal a b=
  (* JSON integer literals may decode to [Int] on disk even when a caller
     supplied [Intlit]. Compare their actual serialized JSON values. *)
  let decoded value=Yojson.Safe.from_string (Yojson.Safe.to_string value) |> Yojson.Safe.sort in
  Yojson.Safe.equal (decoded a) (decoded b)

(* Only called in the reconciliation's blocking file transaction. Both fsyncs
   use the very descriptors validated by the no-follow owned-root scope. *)
let confirmed_payload ~log_path ~run_id kind ~value ~source =
  let ( let* )=Result.bind in
  match source with
  | In_row -> let* ()=validate_original_json value in Ok value
  | In_file {bytes;sha256} ->
    let root=Filename.dirname log_path in
    let path=payload_path ~log_path ~run_id kind ~sha256 in
    let confirmed=Fs_compat.with_owned_inventory_root root (fun held ->
      let* value=Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid ()) held path
        (fun ~file ~parent ~stat ->
          if stat.Unix.st_size<>bytes then Error "Original payload size changed" else
          let buffer=Bytes.create bytes in
          let rec read offset=if offset=bytes then Ok () else
            match Unix.read file buffer offset (bytes-offset) with
            | 0 -> Error "Original payload shrank during verification"
            | count -> read (offset+count)
            | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
          let* ()=read 0 in
          let text=Bytes.to_string buffer in
          if not (String.equal Digestif.SHA256.(to_hex (digest_string text)) sha256) then
            Error "Original payload digest changed" else
          let* value=try Ok (Yojson.Safe.from_string text) with Yojson.Json_error detail -> Error detail in
          let* ()=validate_original_json value in
          Unix.fsync file;Unix.fsync parent;
          (* The log transaction has synced the log directory. Settle the
             intermediate payload root as well; the enclosing owned file/root
             scopes revalidate its original no-follow chain after this call. *)
          Keeper_fs_durable_directory.fsync_directory
            (Filename.dirname (payload_run_dir ~log_path ~run_id));
          ignore (Unix.lseek file 0 Unix.SEEK_SET : int);
          let* ()=read 0 in
          if not (String.equal text (Bytes.to_string buffer)) then Error "Original payload changed during sync"
          else Ok value) in
      Ok value) in
    (match confirmed with
     | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
     | Ok value -> value)

let rec current_source_error = function
  | Store.Volatile_store -> "A volatile registry cannot confirm a durable receipt"
  | Not_initialized -> "Registry startup authority has not been established"
  | Incomplete_startup _ -> "Registry startup history was incomplete or malformed"
  | Non_regular_history _ -> "Registry history is not a regular file"
  | Invalid_history detail | Read_failed detail -> detail
  | Incomplete_history -> "Registry history has an incomplete tail"
  | Snapshot_changed -> "Registry history changed while being read"
  | Read_cleanup_failed {primary;detail} ->
    (match primary with None -> detail | Some error -> current_source_error error ^ "; " ^ detail)

type reconciliation_refusal =
  | Original_refusal of reconciliation_error
  | Prepare_payload of payload_kind

let reconcile_original t ~run_id ~lane ~actor ~started_at ~input ~completion =
  let ( let* )=Result.bind in
  let invalid value=Result.map_error (fun detail -> Invalid_original detail) value in
  let* ()=if run_id_is_a_segment run_id && Float.is_finite started_at && started_at>=0.
      && String.trim actor<>"" then Ok () else Error (Invalid_original "Invalid original run identity/time/actor") in
  let Exact_input original_input=input in
  let* ()=invalid (validate_original_json original_input) in
  let* ()=match completion with
    | None -> Ok ()
    | Some c ->
      let* ()=match c.elapsed_s with
        | Some elapsed when not (Float.is_finite elapsed) || elapsed<0. -> Error (Invalid_original "Invalid original duration")
        | None | Some _ -> Ok () in
      let* ()=match c.selected_slot with
        | Some slot when String.trim slot="" -> Error (Invalid_original "Invalid original slot")
        | None | Some _ -> Ok () in
      let* ()=invalid (validate_original_json c.output) in
      (match c.usage with None -> Ok () | Some usage -> invalid
        (usage_of_yojson (usage_to_yojson usage) |> Result.map (fun _ -> ()))) in
  let same_completion (actual:Payload.completion) (expected:original_completion)=
    actual.origin=Producer && actual.outcome=expected.outcome && actual.elapsed_s=expected.elapsed_s
    && actual.selected_slot=expected.selected_slot && actual.usage=expected.usage
    && original_json_equal actual.output expected.output in
  match Cross_context_mutex.with_durable_lock t.observation_mutex (fun () ->
    let before=Atomic.get t.projection in
    let prepared_input=ref None and prepared_output=ref None in
    let unavailable value=Result.map_error (fun detail -> Original_refusal (Reconciliation_unavailable detail)) value in
    let decide current=
      let* ()=match List.assoc_opt run_id (Atomic.get t.failed_completions) with
        | None -> Ok ()
        | Some failed ->
          (match completion with
           | Some expected when failed.intended_outcome=expected.outcome && failed.elapsed_s=expected.elapsed_s
               && failed.selected_slot=expected.selected_slot && failed.usage=expected.usage
               && original_json_equal failed.output expected.output -> Ok ()
           | None | Some _ -> Error (Original_refusal Failed_completion_conflict)) in
      let* current=match current,t.path with
        | None,_ -> Ok None
        | Some entry,None -> Ok (Some entry)
        | Some (entry:Store.entry),Some log_path ->
          let Exact_input value=entry.registration.input in
          let* value=unavailable (confirmed_payload ~log_path ~run_id Input_payload
            ~value ~source:entry.registration.input_source) in
          let registration={entry.registration with input=Exact_input value} in
          let* status=match entry.status with
            | Store.Running -> Ok Store.Running
            | Completed c ->
              let* output=unavailable (confirmed_payload ~log_path ~run_id Output_payload
                ~value:c.output ~source:c.output_source) in
              Ok (Store.Completed {c with output}) in
          Ok (Some {entry with registration;status}) in
      let* ()=match current with
        | None -> Ok ()
        | Some entry ->
          let Exact_input actual_input=entry.registration.input in
          if entry.started_at=started_at && entry.registration.lane=lane && entry.registration.actor=actor
            && original_json_equal actual_input original_input then Ok ()
          else Error (Original_refusal Original_registration_conflict) in
      let write kind value=
        let prepared=match kind with Input_payload -> !prepared_input | Output_payload -> !prepared_output in
        match prepared,t.path with
        | None,_ -> Error (Prepare_payload kind)
        | Some _,None -> Error (Original_refusal (Reconciliation_unavailable "A volatile registry cannot publish original receipts"))
        | Some source,Some log_path ->
          let* actual=unavailable (confirmed_payload ~log_path ~run_id kind ~value ~source) in
          if original_json_equal actual value then Ok source
          else Error (Original_refusal (Reconciliation_unavailable "Prepared original payload changed")) in
      let publish_completion (c:original_completion)=
        let* output_source=write Output_payload c.output in
        Ok {Payload.outcome=c.outcome;origin=Producer;elapsed_s=c.elapsed_s;output=c.output;
          output_source;selected_slot=c.selected_slot;usage=c.usage} in
      match current,completion with
      | None,completion ->
        let* input_source=write Input_payload original_input in
        let* completion=match completion with None -> Ok None
          | Some c -> Result.map Option.some (publish_completion c) in
        Ok (Store.Register_original {started_at;registration={Payload.lane;actor;input;input_source};completion},())
      | Some _,None -> Ok (Store.Confirm_current,())
      | Some {status=Store.Running;_},Some c ->
        let* completion=publish_completion c in Ok (Store.Complete_original completion,())
      | Some {status=Store.Completed actual;_},Some expected ->
        if same_completion actual expected then Ok (Store.Confirm_current,()) else
        match actual.origin with
        | Producer -> Error (Original_refusal Original_completion_conflict)
        | Restart_replay -> let* completion=publish_completion expected in
          Ok (Store.Complete_original completion,()) in
    (* Payload directory preparation may wait on another Eio preparation. It
       runs on the caller under the observation lock, never inside the blocking
       log callback. Each typed request fills one immutable payload slot. The
       next transaction freshly validates the entire log and those exact bytes;
       a changed original refuses instead of inheriting the earlier decision. *)
    let rec reconcile ()=
      match Store.reconcile_current t.store ~id:run_id ~decide with
      | Error (Store.Decision_refused (Prepare_payload kind)) ->
        let value=match kind,completion with
          | Input_payload,_ -> Ok original_input
          | Output_payload,Some c -> Ok c.output
          | Output_payload,None -> Error "Original output requires an actual completion" in
        (match value,t.path with
         | Error detail,_ -> Error (Store.Invalid_change detail)
         | Ok _,None -> Error (Store.Decision_refused (Original_refusal
             (Reconciliation_unavailable "A volatile registry cannot publish original receipts")))
         | Ok value,Some log_path ->
           match write_payload ~log_path ~run_id kind value with
           | Error detail -> Error (Store.Decision_refused (Original_refusal (Reconciliation_unavailable detail)))
           | Ok source ->
             (match kind with Input_payload -> prepared_input:=Some source | Output_payload -> prepared_output:=Some source);
             reconcile ())
      | Ok value -> Ok value
      | Error ((Store.Current_source_unavailable _ | Invalid_change _ | Publication_failed _
          | Decision_refused (Original_refusal _)) as error) -> Error error in
    match reconcile () with
    | Error (Store.Decision_refused (Original_refusal error)) -> Error error
    | Error (Store.Decision_refused (Prepare_payload _)) ->
      Error (Reconciliation_unavailable "Original payload preparation did not settle")
    | Error (Current_source_unavailable error) -> Error (Reconciliation_unavailable (current_source_error error))
    | Error (Invalid_change detail) -> Error (Invalid_original detail)
    | Error (Publication_failed failure) ->
      let state=match failure.state with Run_registry_core.Not_persisted -> Not_persisted
        | Durability_unknown -> Durability_unknown in
      Error (Reconciliation_persistence_failed {detail=failure.detail;state})
    | Ok () ->
      remove_failed_completion t run_id;publish_projection t;
      Ok (before<>Atomic.get t.projection)) with
  | Ok changed -> if changed then notify_changed (); Ok ()
  | Error error -> Error error
  | exception ((Sys_error _ | Unix.Unix_error _) as exn) ->
    Error (Reconciliation_persistence_failed {detail=Printexc.to_string exn;state=Durability_unknown})
;;

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

(* A detail read opens the run's payload file and checks it against the size
   and SHA-256 its row recorded. It never reads the log. *)
let read_payload_file ~log_path ~run_id kind ~bytes ~sha256 ~missing =
  let path = payload_path ~log_path ~run_id kind ~sha256 in
  match Fs_compat.load_file path with
  | exception Sys_error detail ->
    (match Unix.stat path with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error missing
     | exception Unix.Unix_error (error, operation, _) ->
       Error (Source_unavailable (Printf.sprintf "%s: %s" operation (Unix.error_message error)))
     | _ -> Error (Source_unavailable detail))
  | text when String.length text <> bytes ->
    Error
      (Invalid_payload
         (Printf.sprintf "%s holds %d bytes; its row recorded %d" path (String.length text) bytes))
  | text when not (String.equal (Digestif.SHA256.(digest_string text |> to_hex)) sha256) ->
    Error (Invalid_payload (Printf.sprintf "%s does not match the SHA-256 its row recorded" path))
  | text ->
    (match Yojson.Safe.from_string text with
     | value -> Ok value
     | exception Yojson.Json_error detail ->
       Error (Invalid_payload (Printf.sprintf "%s is not JSON: %s" path detail)))
;;

let payload_value ~log_path ~run_id kind ~value ~source ~missing =
  match source with
  | In_row -> Ok value
  | In_file { bytes; sha256 } -> read_payload_file ~log_path ~run_id kind ~bytes ~sha256 ~missing
;;

let availability_of = function
  | Ok _ -> Available
  | Error error -> Unavailable error
;;

let selected_entry t run_id =
  Store.get_metadata t.store ~id:run_id
;;

let get t ~run_id =
  match selected_entry t run_id with
  | None -> None
  | Some entry ->
    let failed_completions = Atomic.get t.failed_completions in
    let base_run = full_run_of_entry failed_completions entry in
    (match t.path with
     | None -> Some base_run
     | Some log_path ->
       let read kind ~value ~source ~missing =
         Eio_guard.run_in_systhread ~label:"exact-lane-payload-read" (fun () ->
           payload_value ~log_path ~run_id kind ~value ~source ~missing)
       in
       let input =
         match entry.registration.input with
         | Exact_input value ->
           read
             Input_payload
             ~value
             ~source:entry.registration.input_source
             ~missing:Missing_registration
       in
       let stored_output =
         match entry.status with
         | Store.Running -> None
         | Store.Completed completion ->
           Some
             ( completion
             , read
                 Output_payload
                 ~value:completion.output
                 ~source:completion.output_source
                 ~missing:Missing_completion )
       in
       let unchanged =
         Option.equal ( == ) (Some entry) (selected_entry t run_id)
         && Option.equal ( == ) (List.assoc_opt run_id failed_completions)
              (List.assoc_opt run_id (Atomic.get t.failed_completions))
       in
       let settled read = if unchanged then read else Error Snapshot_changed in
       let input = settled input in
       let value_or_null = function
         | Ok value -> value
         | Error _ -> `Null
       in
       let status, output_availability =
         match stored_output, List.assoc_opt run_id failed_completions with
         | Some (completion, output), _ ->
           (* A committed completion always wins over a diagnostic overlay. *)
           let output = settled output in
           ( Completed
               { outcome = completion.outcome
               ; origin = completion.origin
               ; elapsed_s = completion.elapsed_s
               ; output = value_or_null output
               ; selected_slot = completion.selected_slot
               ; usage = completion.usage
               }
           , Some (availability_of output) )
         | None, Some failed ->
           (* The failed append retained this exact output in memory. *)
           ( Completion_persistence_failed
               { intended_outcome = failed.intended_outcome
               ; elapsed_s = failed.elapsed_s
               ; output = failed.output
               ; selected_slot = failed.selected_slot
               ; usage = failed.usage
               ; failure = failed.failure
               }
           , Some Available )
         | None, None -> Running, None
       in
       Some
         { base_run with
           input = Exact_input (value_or_null input)
         ; input_availability = availability_of input
         ; status
         ; output_availability
         })
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
    ; "lane", `String (lane_id run.lane)
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
    | Completed { outcome; origin; elapsed_s; output = _; selected_slot; usage } ->
      let detail =
        match outcome with
        | Succeeded | Cancelled -> []
        | Failed { code; detail } ->
          [ "code", `String code; "detail", `String detail ]
      in
      [ "completion_origin", `String (match origin with Producer -> "producer" | Restart_replay -> "restart_replay")
      ; "elapsed_s", (match elapsed_s with None -> `Null | Some value -> `Float value)
      ; ( "selected_slot"
        , match selected_slot with
          | None -> `Null
          | Some selected_slot -> `String selected_slot )
      ; ( "usage"
        , match usage with
          | None -> `Null
          | Some usage -> usage_to_yojson usage )
      ]
      @ detail
    | Completion_persistence_failed
        { intended_outcome; elapsed_s; output = _; selected_slot; usage; failure } ->
      let intended_failure =
        match intended_outcome with
        | Succeeded | Cancelled -> []
        | Failed { code; detail } ->
          [ "intended_code", `String code; "intended_detail", `String detail ]
      in
      [ "intended_status", `String (outcome_label intended_outcome)
      ; "completion_origin", `String "producer"
      ; "elapsed_s", (match elapsed_s with None -> `Null | Some value -> `Float value)
      ; ( "selected_slot"
        , match selected_slot with
          | None -> `Null
          | Some selected_slot -> `String selected_slot )
      ; ( "usage"
        , match usage with
          | None -> `Null
          | Some usage -> usage_to_yojson usage )
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
  let payload_availability =
    `Assoc
      [ "input", availability_to_yojson run.input_availability
      ; "output", (match run.output_availability with
                   | None -> `Null
                   | Some availability -> availability_to_yojson availability)
      ]
  in
  `Assoc
    (run_summary_fields run
     @ [ "input", input_to_yojson run.input
       ; "payload_availability", payload_availability ]
     @ output_field)
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
