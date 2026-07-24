(* See .mli. *)

module Candidate = Keeper_board_attention_candidate
module Id_map = Map.Make (String)
module Id_set = Set.Make (String)

module Worker_epoch = struct
  type t = Uuidm.t

  let prefix = "board-attention-worker-"
  (* NDT-OK: entropy is opaque process identity only; scheduling never branches
     on random contents. Stdlib mutex is required because generation can occur
     before or outside an Eio scheduler and the critical section never yields. *)
  let rng = Random.State.make_self_init ()
  let mutex = Stdlib.Mutex.create ()

  let generate () =
    Stdlib.Mutex.protect mutex (fun () -> Uuidm.v4_gen rng ())
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if String.length value <> prefix_length + 36
       || not (String.equal (String.sub value 0 prefix_length) prefix)
    then Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
    else
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some uuid -> Ok uuid
      | None -> Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
  ;;

  let to_string value = prefix ^ Uuidm.to_string value
  let equal = Uuidm.equal
end

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type exact_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type running_progress =
  | Unbound
  | Bound of exact_provenance
  | Advancing of
      { failed : exact_provenance
      ; next : exact_provenance
      }

type blocked_reason =
  | Candidate_membership_conflict of string
  | Durable_partition_invariant of string
  | Exact_setup_unavailable of string
  | Exact_flow_replayed
  | Exact_execution_terminal
  | Domain_output_invalid of string
  | Execution_provenance_mismatch of string
  | Unexpected_worker_failure of string
  | Exact_execution_quarantined of running_progress

type running_state =
  { worker_epoch : Worker_epoch.t
  ; started_at : float
  ; progress : running_progress
  }

type state =
  | Ready
  | Running of running_state
  | Completed of
      { item : completed_item
      ; completed_at : float
      }
  | Settled of { settled_at : float }
  | Blocked of
      { reason : blocked_reason
      ; blocked_at : float
      }

type t =
  { partition_id : string
  ; keeper_name : string
  ; context_key : Candidate.Context_key.t
  ; candidate_id : string
  ; created_at : float
  ; state : state
  }

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_transition =
  { partition : t
  ; changed : bool
  ; write_outcome : exact_write_outcome
  }

type requeue_blocked_outcome =
  | Requeued of exact_transition
  | Cursor_conflict of string
  | Generation_conflict of string

let ( let* ) = Result.bind
let schema_version = 4

let state_to_string = function
  | Ready -> "ready"
  | Running _ -> "running"
  | Completed _ -> "completed"
  | Settled _ -> "settled"
  | Blocked _ -> "blocked"
;;

let exact_provenance_to_yojson provenance =
  `Assoc
    [ "slot_id", `String provenance.slot_id
    ; "call_id", `String provenance.call_id
    ; "plan_fingerprint", `String provenance.plan_fingerprint
    ; "request_body_sha256", `String provenance.request_body_sha256
    ]
;;

let running_progress_to_yojson = function
  | Unbound -> `Assoc [ "kind", `String "unbound" ]
  | Bound provenance ->
    `Assoc
      [ "kind", `String "bound"
      ; "provenance", exact_provenance_to_yojson provenance
      ]
  | Advancing { failed; next } ->
    `Assoc
      [ "kind", `String "advancing"
      ; "failed", exact_provenance_to_yojson failed
      ; "next", exact_provenance_to_yojson next
      ]
;;

let blocked_reason_to_yojson = function
  | Candidate_membership_conflict detail ->
    `Assoc [ "kind", `String "candidate_membership_conflict"; "detail", `String detail ]
  | Durable_partition_invariant detail ->
    `Assoc [ "kind", `String "durable_partition_invariant"; "detail", `String detail ]
  | Exact_setup_unavailable detail ->
    `Assoc [ "kind", `String "exact_setup_unavailable"; "detail", `String detail ]
  | Exact_flow_replayed -> `Assoc [ "kind", `String "exact_flow_replayed" ]
  | Exact_execution_terminal ->
    `Assoc [ "kind", `String "exact_execution_terminal" ]
  | Domain_output_invalid detail ->
    `Assoc [ "kind", `String "domain_output_invalid"; "detail", `String detail ]
  | Execution_provenance_mismatch detail ->
    `Assoc
      [ "kind", `String "execution_provenance_mismatch"
      ; "detail", `String detail
      ]
  | Unexpected_worker_failure detail ->
    `Assoc [ "kind", `String "unexpected_worker_failure"; "detail", `String detail ]
  | Exact_execution_quarantined progress ->
    `Assoc
      [ "kind", `String "exact_execution_quarantined"
      ; "progress", running_progress_to_yojson progress
      ]
;;

let completed_item_to_yojson (item : completed_item) =
  `Assoc
    [ "candidate_id", `String item.candidate_id
    ; "judgment", Candidate.judgment_to_yojson item.judgment
    ]
;;

let state_to_yojson = function
  | Ready -> `Assoc [ "kind", `String "ready" ]
  | Running { worker_epoch; started_at; progress } ->
    `Assoc
      [ "kind", `String "running"
      ; "worker_epoch", `String (Worker_epoch.to_string worker_epoch)
      ; "started_at", `Float started_at
      ; "progress", running_progress_to_yojson progress
      ]
  | Completed { item; completed_at } ->
    `Assoc
      [ "kind", `String "completed"
      ; "item", completed_item_to_yojson item
      ; "completed_at", `Float completed_at
      ]
  | Settled { settled_at } ->
    `Assoc [ "kind", `String "settled"; "settled_at", `Float settled_at ]
  | Blocked { reason; blocked_at } ->
    `Assoc
      [ "kind", `String "blocked"
      ; "reason", blocked_reason_to_yojson reason
      ; "blocked_at", `Float blocked_at
      ]
;;

let to_yojson partition =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "partition_id", `String partition.partition_id
    ; "keeper_name", `String partition.keeper_name
    ; "context_key", Candidate.Context_key.to_yojson partition.context_key
    ; "candidate_id", `String partition.candidate_id
    ; "created_at", `Float partition.created_at
    ; "state", state_to_yojson partition.state
    ]
;;

let assoc ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be an object")
;;

let exact_fields ~context expected fields =
  let actual = List.map fst fields in
  if List.length actual = List.length expected
     && List.for_all (fun key -> List.mem key actual) expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let field ~context key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing field %s" context key)
;;

let string_json ~context = function
  | `String value when not (String.equal value "") -> Ok value
  | `String _ -> Error (context ^ " must not be empty")
  | _ -> Error (context ^ " must be a string")
;;

let float_json ~context = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Float _ -> Error (context ^ " must be finite")
  | _ -> Error (context ^ " must be a number")
;;

let exact_provenance_of_yojson json =
  let context = "Board attention exact provenance" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "slot_id"; "call_id"; "plan_fingerprint"; "request_body_sha256" ]
      fields
  in
  let* slot_json = field ~context "slot_id" fields in
  let* slot_id = string_json ~context:(context ^ ".slot_id") slot_json in
  let* call_json = field ~context "call_id" fields in
  let* call_id = string_json ~context:(context ^ ".call_id") call_json in
  let* fingerprint_json = field ~context "plan_fingerprint" fields in
  let* plan_fingerprint =
    string_json ~context:(context ^ ".plan_fingerprint") fingerprint_json
  in
  let* body_json = field ~context "request_body_sha256" fields in
  let* request_body_sha256 =
    string_json ~context:(context ^ ".request_body_sha256") body_json
  in
  Ok { slot_id; call_id; plan_fingerprint; request_body_sha256 }
;;

let running_progress_of_yojson json =
  let context = "Board attention exact progress" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "unbound" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Unbound
  | "bound" ->
    let* () = exact_fields ~context [ "kind"; "provenance" ] fields in
    let* provenance_json = field ~context "provenance" fields in
    let* provenance = exact_provenance_of_yojson provenance_json in
    Ok (Bound provenance)
  | "advancing" ->
    let* () = exact_fields ~context [ "kind"; "failed"; "next" ] fields in
    let* failed_json = field ~context "failed" fields in
    let* failed = exact_provenance_of_yojson failed_json in
    let* next_json = field ~context "next" fields in
    let* next = exact_provenance_of_yojson next_json in
    Ok (Advancing { failed; next })
  | value -> Error (Printf.sprintf "unknown Board attention exact progress %S" value)
;;

let blocked_reason_of_yojson json =
  let context = "Board attention blocked reason" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "candidate_membership_conflict" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Candidate_membership_conflict detail)
  | "durable_partition_invariant" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Durable_partition_invariant detail)
  | "exact_setup_unavailable" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Exact_setup_unavailable detail)
  | "exact_flow_replayed" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Exact_flow_replayed
  | "exact_execution_terminal" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Exact_execution_terminal
  | "domain_output_invalid" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Domain_output_invalid detail)
  | "execution_provenance_mismatch" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Execution_provenance_mismatch detail)
  | "unexpected_worker_failure" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Unexpected_worker_failure detail)
  | "exact_execution_quarantined" ->
    let* () = exact_fields ~context [ "kind"; "progress" ] fields in
    let* progress_json = field ~context "progress" fields in
    let* progress = running_progress_of_yojson progress_json in
    (match progress with
     | Bound _ | Advancing _ -> Ok (Exact_execution_quarantined progress)
     | Unbound -> Error "unbound execution cannot be quarantined")
  | value -> Error (Printf.sprintf "unknown Board attention blocked reason %S" value)
;;

let completed_item_of_yojson json =
  let context = "Board attention completed item" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "candidate_id"; "judgment" ] fields in
  let* candidate_id_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_id_json in
  let* judgment_json = field ~context "judgment" fields in
  let* judgment = Candidate.judgment_of_yojson judgment_json in
  Ok { candidate_id; judgment }
;;

let state_of_yojson json =
  let context = "Board attention partition state" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "ready" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Ready
  | "running" ->
    let* () =
      exact_fields ~context [ "kind"; "worker_epoch"; "started_at"; "progress" ] fields
    in
    let* epoch_json = field ~context "worker_epoch" fields in
    let* epoch_raw = string_json ~context:(context ^ ".worker_epoch") epoch_json in
    let* worker_epoch = Worker_epoch.of_string epoch_raw in
    let* started_json = field ~context "started_at" fields in
    let* started_at = float_json ~context:(context ^ ".started_at") started_json in
    let* progress_json = field ~context "progress" fields in
    let* progress = running_progress_of_yojson progress_json in
    Ok (Running { worker_epoch; started_at; progress })
  | "completed" ->
    let* () = exact_fields ~context [ "kind"; "item"; "completed_at" ] fields in
    let* item_json = field ~context "item" fields in
    let* item = completed_item_of_yojson item_json in
    let* completed_json = field ~context "completed_at" fields in
    let* completed_at = float_json ~context:(context ^ ".completed_at") completed_json in
    Ok (Completed { item; completed_at })
  | "settled" ->
    let* () = exact_fields ~context [ "kind"; "settled_at" ] fields in
    let* settled_json = field ~context "settled_at" fields in
    let* settled_at = float_json ~context:(context ^ ".settled_at") settled_json in
    Ok (Settled { settled_at })
  | "blocked" ->
    let* () = exact_fields ~context [ "kind"; "reason"; "blocked_at" ] fields in
    let* reason_json = field ~context "reason" fields in
    let* reason = blocked_reason_of_yojson reason_json in
    let* blocked_json = field ~context "blocked_at" fields in
    let* blocked_at = float_json ~context:(context ^ ".blocked_at") blocked_json in
    Ok (Blocked { reason; blocked_at })
  | value -> Error (Printf.sprintf "unknown Board attention partition state %S" value)
;;

let of_yojson json =
  let context = "Board attention partition" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "schema_version"
      ; "partition_id"
      ; "keeper_name"
      ; "context_key"
      ; "candidate_id"
      ; "created_at"
      ; "state"
      ]
      fields
  in
  let* version_json = field ~context "schema_version" fields in
  let* () =
    match version_json with
    | `Int version when Int.equal version schema_version -> Ok ()
    | `Int version ->
      Error
        (Printf.sprintf
           "unsupported Board attention partition schema version %d"
           version)
    | _ -> Error (context ^ ".schema_version must be an integer")
  in
  let* partition_json = field ~context "partition_id" fields in
  let* partition_id = string_json ~context:(context ^ ".partition_id") partition_json in
  let* keeper_json = field ~context "keeper_name" fields in
  let* keeper_name = string_json ~context:(context ^ ".keeper_name") keeper_json in
  let* context_json = field ~context "context_key" fields in
  let* context_key = Candidate.Context_key.of_yojson context_json in
  let* candidate_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_json in
  let* created_json = field ~context "created_at" fields in
  let* created_at = float_json ~context:(context ^ ".created_at") created_json in
  let* state_json = field ~context "state" fields in
  let* state = state_of_yojson state_json in
  let* () =
    match state with
    | Completed { item; _ } when String.equal item.candidate_id candidate_id -> Ok ()
    | Completed _ -> Error "completed item identity differs from partition candidate"
    | Ready | Running _ | Settled _ | Blocked _ -> Ok ()
  in
  Ok { partition_id; keeper_name; context_key; candidate_id; created_at; state }
;;

let partition_dir base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "board_attention_partitions"
;;

let path ~base_path ~keeper_name =
  Filename.concat
    (partition_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let parse content =
  String.split_on_char '\n' content
  |> List.fold_left
       (fun result line ->
          let* rows = result in
          let line = String.trim line in
          if String.equal line ""
          then Ok rows
          else
            match Yojson.Safe.from_string line with
            | json ->
              let* row = of_yojson json in
              Ok (row :: rows)
            | exception Yojson.Json_error detail -> Error ("invalid partition JSON: " ^ detail))
       (Ok [])
  |> Result.map List.rev
;;

let serialize rows =
  rows
  |> List.map (fun row -> Yojson.Safe.to_string (to_yojson row) ^ "\n")
  |> String.concat ""
;;

let framed values =
  values
  |> List.map (fun value -> Printf.sprintf "%d:%s" (String.length value) value)
  |> String.concat ""
;;

let root_id ~keeper_name ~context_key ~candidate_id =
  let payload =
    framed
      [ "singleton"
      ; keeper_name
      ; Candidate.Context_key.to_canonical_string context_key
      ; candidate_id
      ]
  in
  "ba-root-" ^ Digestif.SHA256.(digest_string payload |> to_hex)
;;

module Ready_order = struct
  type nonrec t =
    { created_at : float
    ; partition_id : string
    }

  let compare left right =
    match Float.compare left.created_at right.created_at with
    | 0 -> String.compare left.partition_id right.partition_id
    | ordering -> ordering
  ;;
end

module Ready_set = Set.Make (Ready_order)

type view =
  { cursor : Fs_compat.Private_jsonl_cursor.t
  ; by_id : t Id_map.t
  ; ready : Ready_set.t
  ; completed : Id_set.t
  ; live_candidate_owner : string Id_map.t
  }

let empty_view cursor =
  { cursor
  ; by_id = Id_map.empty
  ; ready = Ready_set.empty
  ; completed = Id_set.empty
  ; live_candidate_owner = Id_map.empty
  }
;;

let is_live = function
  | Ready | Running _ | Completed _ | Blocked _ -> true
  | Settled _ -> false
;;

let compare_partition left right =
  match Float.compare left.created_at right.created_at with
  | 0 -> String.compare left.partition_id right.partition_id
  | ordering -> ordering
;;

let ready_order partition : Ready_order.t =
  { created_at = partition.created_at; partition_id = partition.partition_id }
;;

let remove_partition_indexes view partition =
  let ready =
    match partition.state with
    | Ready -> Ready_set.remove (ready_order partition) view.ready
    | Running _ | Completed _ | Settled _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.remove partition.partition_id view.completed
    | Ready | Running _ | Settled _ | Blocked _ -> view.completed
  in
  let live_candidate_owner =
    if is_live partition.state
    then Id_map.remove partition.candidate_id view.live_candidate_owner
    else view.live_candidate_owner
  in
  { view with ready; completed; live_candidate_owner }
;;

let add_partition_indexes view partition =
  let* live_candidate_owner =
    if not (is_live partition.state)
    then Ok view.live_candidate_owner
    else
      match Id_map.find_opt partition.candidate_id view.live_candidate_owner with
      | None ->
        Ok
          (Id_map.add
             partition.candidate_id
             partition.partition_id
             view.live_candidate_owner)
      | Some existing ->
        Error
          (Printf.sprintf
             "candidate %s belongs to live partitions %s and %s"
             partition.candidate_id
             existing
             partition.partition_id)
  in
  let ready =
    match partition.state with
    | Ready -> Ready_set.add (ready_order partition) view.ready
    | Running _ | Completed _ | Settled _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.add partition.partition_id view.completed
    | Ready | Running _ | Settled _ | Blocked _ -> view.completed
  in
  Ok
    { view with
      by_id = Id_map.add partition.partition_id partition view.by_id
    ; ready
    ; completed
    ; live_candidate_owner
    }
;;

let same_partition_identity left right =
  String.equal left.partition_id right.partition_id
  && String.equal left.keeper_name right.keeper_name
  && Candidate.Context_key.equal left.context_key right.context_key
  && String.equal left.candidate_id right.candidate_id
  && Float.equal left.created_at right.created_at
;;

let legal_transition previous next =
  match previous, next with
  | Ready, Running { progress = Unbound; _ } -> true
  | Running { progress = Unbound; _ }, Ready -> true
  | Running { progress = Unbound; _ }, Running { progress = Bound _; _ } -> true
  | Running { progress = Bound _; _ }, Running { progress = Advancing _; _ } -> true
  | Running { progress = Advancing _; _ }, Running { progress = Bound _; _ } -> true
  | Running { progress = Bound _; _ }, Completed _ -> true
  | Running _, Blocked _ -> true
  | Blocked _, Ready -> true
  | (Completed _ | Blocked _), Settled _ -> true
  | Ready, _
  | Running _, _
  | Completed _, _
  | Settled _, _
  | Blocked _, _ -> false
;;

let validate_root_identity partition =
  let expected =
    root_id
      ~keeper_name:partition.keeper_name
      ~context_key:partition.context_key
      ~candidate_id:partition.candidate_id
  in
  if String.equal expected partition.partition_id
  then Ok ()
  else
    Error
      (Printf.sprintf
         "partition root identity mismatch expected=%s observed=%s"
         expected
         partition.partition_id)
;;

let apply_row view partition =
  let* () = validate_root_identity partition in
  match Id_map.find_opt partition.partition_id view.by_id with
  | None -> add_partition_indexes view partition
  | Some previous ->
    if not (same_partition_identity previous partition)
    then Error ("partition changed immutable identity: " ^ partition.partition_id)
    else if previous = partition
    then Ok view
    else if not (legal_transition previous.state partition.state)
    then
      Error
        (Printf.sprintf
           "partition %s illegal transition %s -> %s"
           partition.partition_id
           (state_to_string previous.state)
           (state_to_string partition.state))
    else
      add_partition_indexes (remove_partition_indexes view previous) partition
;;

let apply_rows view rows =
  List.fold_left
    (fun result partition ->
       let* view = result in
       apply_row view partition)
    (Ok view)
    rows
;;

let view_partitions view =
  view.by_id
  |> Id_map.bindings
  |> List.map snd
  |> List.sort compare_partition
;;

type cache_entry =
  { cached : view option Atomic.t
  ; mutation_mutex : Stdlib.Mutex.t
  }

let cache_registry : (string, cache_entry) Hashtbl.t = Hashtbl.create 32
let cache_registry_mutex = Stdlib.Mutex.create ()

let cache_entry ledger_path =
  Stdlib.Mutex.protect cache_registry_mutex (fun () ->
    match Hashtbl.find_opt cache_registry ledger_path with
    | Some entry -> entry
    | None ->
      let entry =
        { cached = Atomic.make None; mutation_mutex = Stdlib.Mutex.create () }
      in
      Hashtbl.add cache_registry ledger_path entry;
      entry)
;;

let run_blocking label operation =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_unix.run_in_systhread ~label operation
  | exception Effect.Unhandled _ -> operation ()
;;

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

let observe_settlement_warning ~ledger_path error =
  Log.Keeper.error
    "board_attention_partition: descriptor settlement incomplete ledger=%s detail=%s"
    ledger_path
    (store_error error)
;;

let snapshot_result ~ledger_path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let cursor_result ~ledger_path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let exact_cursor_result ~ledger_path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error = None } -> Ok (value, Fsync_completed)
  | Ok { value; settlement_error = Some error } ->
    observe_settlement_warning ~ledger_path error;
    Ok (value, Visible_sync_unconfirmed (store_error error))
;;

let invalidate_cached entry observed =
  (* fire-and-forget: false means a concurrent writer won; the loser simply keeps no stale cache *)
  ignore (Atomic.compare_and_set entry.cached observed None : bool)
;;

let publish_cached entry observed view =
  (* fire-and-forget: false means a concurrent writer won; readers fall back to recomputing *)
  ignore (Atomic.compare_and_set entry.cached observed (Some view) : bool)
;;

let read_view_blocking ledger_path =
  let entry = cache_entry ledger_path in
  let observed = Atomic.get entry.cached in
  let after = Option.map (fun view -> view.cursor) observed in
  match
    Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after
    |> snapshot_result ~ledger_path
  with
  | Error error ->
    invalidate_cached entry observed;
    Error error
  | Ok snapshot ->
    let* rows = parse snapshot.bytes in
    let base =
      match observed with
      | Some view -> view
      | None -> empty_view snapshot.cursor
    in
    let* view = apply_rows base rows in
    let view = { view with cursor = snapshot.cursor } in
    publish_cached entry observed view;
    Ok view
;;

let read_view ledger_path =
  run_blocking "board-attention-partition-read" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () -> read_view_blocking ledger_path))
;;

let validate_keeper_identity ~keeper_name view =
  Id_map.fold
    (fun _ partition result ->
       let* () = result in
       if String.equal partition.keeper_name keeper_name
       then Ok ()
       else
         Error
           (Printf.sprintf
              "Board attention partition keeper mismatch expected=%s actual=%s partition=%s"
              keeper_name
              partition.keeper_name
              partition.partition_id))
    view.by_id
    (Ok ())
;;

let load ~base_path ~keeper_name =
  let* view = read_view (path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  Ok (view_partitions view)
;;

let update ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-update" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* rows, result = decide view in
      match rows with
      | [] -> Ok result
      | _ :: _ ->
        let* updated = apply_rows view rows in
        let suffix = serialize rows in
        (match
           Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
             ledger_path
             ~expected:view.cursor
             suffix
           |> cursor_result ~ledger_path
         with
         | Error error -> Error error
         | Ok cursor ->
           Atomic.set entry.cached (Some { updated with cursor });
           Ok result)))
;;

let update_exact ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-update" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* rows, result = decide view in
      match rows with
      | [] -> Error "exact partition update must append a cursor-fenced row"
      | _ :: _ ->
        let* updated = apply_rows view rows in
        let suffix = serialize rows in
        (match
           Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
             ledger_path
             ~expected:view.cursor
             suffix
           |> exact_cursor_result ~ledger_path
         with
         | Error error -> Error error
         | Ok (cursor, write_outcome) ->
           Atomic.set entry.cached (Some { updated with cursor });
           Ok (result, write_outcome))))
;;

let compare_candidate left right =
  match Float.compare left.Candidate.recorded_at right.Candidate.recorded_at with
  | 0 -> String.compare left.candidate_id right.candidate_id
  | ordering -> ordering
;;

let valid_time label value =
  if Float.is_finite value then Ok () else Error (label ^ " must be finite")
;;

let nonempty label value =
  if String.equal (String.trim value) "" then Error (label ^ " must not be empty") else Ok ()
;;

let validate_judgment (judgment : Candidate.judgment) =
  let* () = nonempty "partition judgment slot_id" judgment.slot_id in
  let* () = nonempty "partition judgment call_id" judgment.call_id in
  let* () =
    nonempty "partition judgment plan_fingerprint" judgment.plan_fingerprint
  in
  let* () =
    nonempty "partition judgment request_body_sha256" judgment.request_body_sha256
  in
  let* () = valid_time "partition judgment judged_at" judgment.judged_at in
  Keeper_board_attention_judgment.of_yojson
    (Keeper_board_attention_judgment.to_yojson judgment.verdict)
  |> Result.map ignore
;;

let validate_exact_provenance provenance =
  let* () = nonempty "partition exact provenance slot_id" provenance.slot_id in
  let* () = nonempty "partition exact provenance call_id" provenance.call_id in
  let* () =
    nonempty
      "partition exact provenance plan_fingerprint"
      provenance.plan_fingerprint
  in
  nonempty
    "partition exact provenance request_body_sha256"
    provenance.request_body_sha256
;;

let exact_provenance_equal left right =
  String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let judgment_provenance (judgment : Candidate.judgment) =
  { slot_id = judgment.slot_id
  ; call_id = judgment.call_id
  ; plan_fingerprint = judgment.plan_fingerprint
  ; request_body_sha256 = judgment.request_body_sha256
  }
;;

let validate_blocked_reason = function
  | Candidate_membership_conflict detail ->
    nonempty "candidate membership conflict detail" detail
  | Durable_partition_invariant detail ->
    nonempty "durable partition invariant detail" detail
  | Exact_setup_unavailable detail ->
    nonempty "exact setup unavailable detail" detail
  | Exact_flow_replayed -> Ok ()
  | Exact_execution_terminal -> Ok ()
  | Domain_output_invalid detail ->
    nonempty "domain output invalid detail" detail
  | Execution_provenance_mismatch detail ->
    nonempty "execution provenance mismatch detail" detail
  | Unexpected_worker_failure detail ->
    nonempty "unexpected worker failure detail" detail
  | Exact_execution_quarantined (Bound provenance) ->
    validate_exact_provenance provenance
  | Exact_execution_quarantined (Advancing { failed; next }) ->
    let* () = validate_exact_provenance failed in
    validate_exact_provenance next
  | Exact_execution_quarantined Unbound ->
    Error "unbound execution cannot be quarantined"
;;

let ensure_roots ~base_path ~keeper_name candidates =
  update ~base_path ~keeper_name (fun view ->
    let* roots =
      candidates
      |> List.sort compare_candidate
      |> List.fold_left
           (fun result (candidate : Candidate.candidate) ->
              let* roots = result in
              if not (String.equal candidate.keeper_name keeper_name)
              then Error "candidate Keeper differs from partition ledger Keeper"
              else
                let* () = valid_time "candidate recorded_at" candidate.recorded_at in
                match Candidate.resumable_status candidate.status with
                | None | Some (Candidate.Resumable_consumed _) -> Ok roots
                | Some
                    (Candidate.Resumable_pending _
                    | Candidate.Resumable_judged _) ->
                  let* context_key = Candidate.Context_key.of_candidate candidate in
                  (match Id_map.find_opt candidate.candidate_id view.live_candidate_owner with
                   | Some owner_id ->
                     (match Id_map.find_opt owner_id view.by_id with
                      | Some owner
                        when Candidate.Context_key.equal owner.context_key context_key
                             && Float.equal owner.created_at candidate.recorded_at -> Ok roots
                      | Some owner ->
                        Error
                          (Printf.sprintf
                             "candidate %s authority differs from live partition %s"
                             candidate.candidate_id
                             owner.partition_id)
                      | None -> Error ("live owner index lost partition " ^ owner_id))
                   | None ->
                     let partition_id =
                       root_id ~keeper_name ~context_key ~candidate_id:candidate.candidate_id
                     in
                     (match Id_map.find_opt partition_id view.by_id with
                      | None ->
                        Ok
                          ({ partition_id
                           ; keeper_name
                           ; context_key
                           ; candidate_id = candidate.candidate_id
                           ; created_at = candidate.recorded_at
                           ; state = Ready
                           }
                           :: roots)
                      | Some historical
                        when String.equal historical.candidate_id candidate.candidate_id
                             && Candidate.Context_key.equal historical.context_key context_key
                             && Float.equal historical.created_at candidate.recorded_at -> Ok roots
                      | Some _ -> Error ("partition identity collision: " ^ partition_id))))
           (Ok [])
      |> Result.map List.rev
    in
    Ok (roots, List.length roots))
;;

let recover_for_process_start ~now ~base_path ~keeper_name =
  let* () = valid_time "partition process-start recovery time" now in
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-process-start" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      match
        (* Process-start recovery only: a torn tail from a mid-append crash is
           truncated to the last complete row; general reads keep hard-failing. *)
        Fs_compat.recover_private_jsonl_durable_locked_result ledger_path
        |> snapshot_result ~ledger_path
      with
      | Error error -> Error error
      | Ok snapshot ->
        let* rows = parse snapshot.bytes in
        let* current = apply_rows (empty_view snapshot.cursor) rows in
        let* () = validate_keeper_identity ~keeper_name current in
        let recovered, latest =
          view_partitions current
          |> List.fold_left
               (fun (recovered, latest) partition ->
                  match partition.state with
                  | Running { progress = Unbound; _ } ->
                    recovered + 1, { partition with state = Ready } :: latest
                  | Running ({ progress = (Bound _ | Advancing _) as progress; _ }) ->
                    ( recovered + 1
                    , { partition with
                        state =
                          Blocked
                            { reason = Exact_execution_quarantined progress
                            ; blocked_at = now
                            }
                      }
                      :: latest )
                  | Ready | Completed _ | Settled _ | Blocked _ ->
                    recovered, partition :: latest)
               (0, [])
        in
        let latest = List.rev latest in
        let canonical = serialize latest in
        if String.equal canonical snapshot.bytes
        then (
          Atomic.set entry.cached (Some current);
          Ok recovered)
        else
          (match
             Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
               ledger_path
               ~expected:snapshot.cursor
               canonical
             |> cursor_result ~ledger_path
           with
           | Error error -> Error error
           | Ok cursor ->
             let* compacted = apply_rows (empty_view cursor) latest in
             Atomic.set entry.cached (Some compacted);
             Ok recovered)))
;;

let claim_ready_exact
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~partition_id
  =
  let* () = valid_time "partition claim time" now in
  let* () = nonempty "partition claim id" partition_id in
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-claim" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      match Id_map.find_opt partition_id view.by_id with
      | None -> Ok None
      | Some selected ->
        (match selected.state with
         | Ready ->
           let claimed =
             { selected with
               state = Running { worker_epoch; started_at = now; progress = Unbound }
             }
           in
           let* updated = apply_rows view [ claimed ] in
           let suffix = serialize [ claimed ] in
           (match
              Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
                ledger_path
                ~expected:view.cursor
                suffix
            with
            | Error (Fs_compat.Cursor_mismatch _) ->
              Atomic.set entry.cached None;
              Ok None
            | append_result ->
              let* cursor = cursor_result ~ledger_path append_result in
              Atomic.set entry.cached (Some { updated with cursor });
              Ok (Some claimed))
         | Running _ | Completed _ | Settled _ | Blocked _ -> Ok None)))
;;

let transition_running ~base_path ~partition ~worker_epoch decide =
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("Board attention partition not found: " ^ partition.partition_id)
    | Some current ->
      (match current.state with
       | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
         let* state = decide running in
         let updated = { current with state } in
         if updated = current then Ok ([], current) else Ok ([ updated ], updated)
       | Running running ->
         Error
           (Printf.sprintf
              "partition %s is owned by worker %s"
              partition.partition_id
              (Worker_epoch.to_string running.worker_epoch))
       | Ready | Completed _ | Settled _ | Blocked _ ->
         Error ("partition is not Running: " ^ partition.partition_id)))
;;

let transition_running_exact ~base_path ~partition ~worker_epoch decide =
  let* (partition, changed), write_outcome =
    update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
      match Id_map.find_opt partition.partition_id view.by_id with
      | None -> Error ("Board attention partition not found: " ^ partition.partition_id)
      | Some current ->
        (match current.state with
         | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
           let* state = decide running in
           let updated = { current with state } in
           Ok ([ updated ], (updated, updated <> current))
         | Running running ->
           Error
             (Printf.sprintf
                "partition %s is owned by worker %s"
                partition.partition_id
                (Worker_epoch.to_string running.worker_epoch))
         | Ready | Completed _ | Settled _ | Blocked _ ->
           Error ("partition is not Running: " ^ partition.partition_id)))
  in
  Ok { partition; changed; write_outcome }
;;

let bind_before_dispatch ~worker_epoch ~base_path ~partition ~provenance =
  let* () = validate_exact_provenance provenance in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match running.progress with
      | Unbound ->
        Ok (Running { running with progress = Bound provenance })
      | Bound current when exact_provenance_equal current provenance ->
        Ok (Running running)
      | Bound _ ->
        Error "before-dispatch binding conflicts with the durable exact provenance"
      | Advancing { next; _ } when exact_provenance_equal next provenance ->
        Ok (Running { running with progress = Bound provenance })
      | Advancing _ ->
        Error "before-dispatch binding differs from the durable next provenance")
;;

let record_before_advance ~worker_epoch ~base_path ~partition ~failed ~next =
  let* () = validate_exact_provenance failed in
  let* () = validate_exact_provenance next in
  if exact_provenance_equal failed next
  then Error "before-advance next provenance must differ from failed provenance"
  else
    transition_running_exact
      ~base_path
      ~partition
      ~worker_epoch
      (fun running ->
        match running.progress with
        | Bound current when exact_provenance_equal current failed ->
          Ok (Running { running with progress = Advancing { failed; next } })
        | Bound _ ->
          Error "before-advance failed provenance differs from the durable binding"
        | Advancing current
          when exact_provenance_equal current.failed failed
               && exact_provenance_equal current.next next -> Ok (Running running)
        | Advancing _ ->
          Error "before-advance pair conflicts with the durable advancement"
        | Unbound -> Error "before-advance requires a durable exact binding")
;;

let validate_completion ~now ~(partition : t) ~(item : completed_item) =
  let* () = valid_time "partition completion time" now in
  let* () = validate_judgment item.judgment in
  if not (String.equal item.candidate_id partition.candidate_id)
  then Error "partition completion candidate identity mismatch"
  else Ok ()
;;

let complete ~now ~worker_epoch ~base_path ~partition ~item =
  let* () = validate_completion ~now ~partition ~item in
  let provenance = judgment_provenance item.judgment in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match running.progress with
      | Bound current when exact_provenance_equal current provenance ->
        Ok (Completed { item; completed_at = now })
      | Bound _ ->
        Error "judgment provenance differs from the durable exact binding"
      | Unbound -> Error "partition completion requires a durable exact binding"
      | Advancing _ -> Error "partition completion cannot bypass pending advancement")
;;

let complete_existing_judgment ~now ~worker_epoch ~base_path ~partition ~item =
  let* () = validate_completion ~now ~partition ~item in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match running.progress with
      | Unbound -> Ok (Completed { item; completed_at = now })
      | Bound _ ->
        Error "existing judgment completion cannot bypass a durable exact binding"
      | Advancing _ ->
        Error "existing judgment completion cannot bypass pending advancement")
;;

let confirm_completed ~base_path ~(partition : t) =
  match partition.state with
  | Completed { item; completed_at } ->
    let* () = validate_completion ~now:completed_at ~partition ~item in
    let* (confirmed, changed), write_outcome =
      update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some ({ state = Completed { item = current_item; _ }; _ } as current)
          when current_item = item -> Ok ([ current ], (current, false))
        | Some { state = Completed _; _ } ->
          Error
            ("completed partition item conflicts with durable state: "
             ^ partition.partition_id)
        | Some _ ->
          Error ("partition is not Completed: " ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Ready | Running _ | Settled _ | Blocked _ ->
    Error ("partition is not Completed: " ^ partition.partition_id)
;;

let block ~now ~worker_epoch ~base_path ~partition reason =
  let* () = valid_time "partition block time" now in
  let* () = validate_blocked_reason reason in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun _ -> Ok (Blocked { reason; blocked_at = now }))
;;

let confirm_blocked ~base_path ~(partition : t) =
  match partition.state with
  | Blocked { reason; blocked_at } ->
    let* () = valid_time "partition block time" blocked_at in
    let* () = validate_blocked_reason reason in
    let* (confirmed, changed), write_outcome =
      update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some ({ state = Blocked current; _ } as durable)
          when current.reason = reason
               && Float.equal current.blocked_at blocked_at ->
          Ok ([ durable ], (durable, false))
        | Some { state = Blocked _; _ } ->
          Error
            ("blocked partition generation conflicts with durable state: "
             ^ partition.partition_id)
        | Some _ ->
          Error ("partition is not Blocked: " ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Ready | Running _ | Completed _ | Settled _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

type requeue_decision =
  | Append_ready of t
  | Observe_cursor_conflict of string
  | Observe_generation_conflict of string

let update_requeue_exact_or_observe ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-observe" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* decision = decide view in
      match decision with
      | `Observe result -> Ok (`Observed result)
      | `Append (rows, result) ->
        (match rows with
         | [] -> Error "exact partition update must append a cursor-fenced row"
         | _ :: _ ->
           let* updated = apply_rows view rows in
           let suffix = serialize rows in
           (match
              Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
                ledger_path
                ~expected:view.cursor
                suffix
            with
            | Error (Fs_compat.Cursor_mismatch _ as conflict) ->
              Ok
                (`Observed
                   (Observe_cursor_conflict
                      (Fs_compat.private_jsonl_transaction_error_to_string
                         conflict)))
            | append_result ->
              (match exact_cursor_result ~ledger_path append_result with
               | Error error -> Error error
               | Ok (cursor, write_outcome) ->
                 Atomic.set entry.cached (Some { updated with cursor });
                 Ok (`Written (result, write_outcome)))))))
;;

let requeue_blocked ~base_path ~(partition : t) =
  match partition.state with
  | Blocked _ ->
    let* outcome =
      update_requeue_exact_or_observe
        ~base_path
        ~keeper_name:partition.keeper_name
        (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some current when current = partition ->
          let ready = { current with state = Ready } in
          Ok (`Append ([ ready ], Append_ready ready))
        | Some { state = Blocked _; _ } ->
          Ok
            (`Observe
               (Observe_generation_conflict
                  ("blocked partition generation changed before manual requeue: "
                   ^ partition.partition_id)))
        | Some { state = Ready | Running _ | Completed _ | Settled _; _ } ->
          Ok
            (`Observe
               (Observe_generation_conflict
                  ("partition already advanced beyond the observed Blocked generation: "
                   ^ partition.partition_id))))
    in
    (match outcome with
     | `Written (Append_ready ready, write_outcome) ->
       Ok
         (Requeued
            { partition = ready
            ; changed = true
            ; write_outcome
            })
     | `Observed (Observe_generation_conflict detail) ->
       Ok (Generation_conflict detail)
     | `Observed (Observe_cursor_conflict detail) ->
       Ok (Cursor_conflict detail)
     | `Written ((Observe_cursor_conflict _ | Observe_generation_conflict _), _)
     | `Observed (Append_ready _) ->
       Error "invalid exact requeue decision")
  | Ready | Running _ | Completed _ | Settled _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

let confirm_ready ~base_path ~(partition : t) =
  match partition.state with
  | Ready ->
    let* (confirmed, changed), write_outcome =
      update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some current when current = partition ->
          Ok ([ current ], (current, false))
        | Some { state = Ready; _ } ->
          Error
            ("ready partition identity changed before fsync confirmation: "
             ^ partition.partition_id)
        | Some { state = Blocked _ | Running _ | Completed _ | Settled _; _ } ->
          Error
            ("partition advanced before Ready fsync confirmation: "
             ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Blocked _ | Running _ | Completed _ | Settled _ ->
    Error ("partition is not Ready: " ^ partition.partition_id)
;;

let completed ~base_path ~keeper_name =
  let* view = read_view (path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  Id_set.fold
    (fun partition_id result ->
       let* completed = result in
       match Id_map.find_opt partition_id view.by_id with
       | Some partition -> Ok (partition :: completed)
       | None -> Error ("completed index lost partition " ^ partition_id))
    view.completed
    (Ok [])
  |> Result.map (List.sort compare_partition)
;;

let settle ~now ~base_path ~partition =
  let* () = valid_time "partition settlement time" now in
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("partition settlement target not found: " ^ partition.partition_id)
    | Some ({ state = Settled _; _ } as current) -> Ok ([], current)
    | Some ({ state = (Completed _ | Blocked _); _ } as current) ->
      let settled = { current with state = Settled { settled_at = now } } in
      Ok ([ settled ], settled)
    | Some current ->
      Error ("only Completed or Blocked partition can settle: " ^ current.partition_id))
;;

module For_testing = struct
  let path = path
end
;;
