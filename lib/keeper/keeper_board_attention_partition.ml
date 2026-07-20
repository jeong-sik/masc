(* See .mli. *)

module Candidate = Keeper_board_attention_candidate
module Failure = Keeper_board_attention_failure
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

type blocked_reason =
  | Candidate_membership_conflict of string
  | Durable_partition_invariant of string
  | Judgment_blocked of Failure.blocked

type state =
  | Ready
  | Running of
      { worker_epoch : Worker_epoch.t
      ; started_at : float
      }
  | Deferred of
      { failure : Failure.retryable
      ; deferred_at : float
      }
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

type completion =
  | Partition_completed of t
  | Partition_deferred of t
  | Partition_blocked of t

type claim_recovery =
  | Claim_released of t
  | Claim_already_transitioned of t

let ( let* ) = Result.bind
let schema_version = 2

let state_to_string = function
  | Ready -> "ready"
  | Running _ -> "running"
  | Deferred _ -> "deferred"
  | Completed _ -> "completed"
  | Settled _ -> "settled"
  | Blocked _ -> "blocked"
;;

let blocked_reason_to_yojson = function
  | Candidate_membership_conflict detail ->
    `Assoc [ "kind", `String "candidate_membership_conflict"; "detail", `String detail ]
  | Durable_partition_invariant detail ->
    `Assoc [ "kind", `String "durable_partition_invariant"; "detail", `String detail ]
  | Judgment_blocked failure ->
    `Assoc
      [ "kind", `String "judgment_blocked"
      ; "failure", Failure.blocked_to_yojson failure
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
  | Running { worker_epoch; started_at } ->
    `Assoc
      [ "kind", `String "running"
      ; "worker_epoch", `String (Worker_epoch.to_string worker_epoch)
      ; "started_at", `Float started_at
      ]
  | Deferred { failure; deferred_at } ->
    `Assoc
      [ "kind", `String "deferred"
      ; "failure", Failure.retryable_to_yojson failure
      ; "deferred_at", `Float deferred_at
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
  | "judgment_blocked" ->
    let* () = exact_fields ~context [ "kind"; "failure" ] fields in
    let* failure_json = field ~context "failure" fields in
    let* failure = Failure.blocked_of_yojson failure_json in
    Ok (Judgment_blocked failure)
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
    let* () = exact_fields ~context [ "kind"; "worker_epoch"; "started_at" ] fields in
    let* epoch_json = field ~context "worker_epoch" fields in
    let* epoch_raw = string_json ~context:(context ^ ".worker_epoch") epoch_json in
    let* worker_epoch = Worker_epoch.of_string epoch_raw in
    let* started_json = field ~context "started_at" fields in
    let* started_at = float_json ~context:(context ^ ".started_at") started_json in
    Ok (Running { worker_epoch; started_at })
  | "deferred" ->
    let* () = exact_fields ~context [ "kind"; "failure"; "deferred_at" ] fields in
    let* failure_json = field ~context "failure" fields in
    let* failure = Failure.retryable_of_yojson failure_json in
    let* deferred_json = field ~context "deferred_at" fields in
    let* deferred_at = float_json ~context:(context ^ ".deferred_at") deferred_json in
    Ok (Deferred { failure; deferred_at })
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
    | Ready | Running _ | Deferred _ | Settled _ | Blocked _ -> Ok ()
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
  | Ready | Running _ | Deferred _ | Completed _ | Blocked _ -> true
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
    | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.remove partition.partition_id view.completed
    | Ready | Running _ | Deferred _ | Settled _ | Blocked _ -> view.completed
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
    | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.add partition.partition_id view.completed
    | Ready | Running _ | Deferred _ | Settled _ | Blocked _ -> view.completed
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
  | Ready, Running _ -> true
  | Running _, (Ready | Deferred _ | Completed _ | Blocked _) -> true
  | Deferred _, Ready -> true
  | Completed _, Settled _ -> true
  | Ready, (Ready | Deferred _ | Completed _ | Settled _ | Blocked _)
  | Running _, (Running _ | Settled _)
  | Deferred _, (Running _ | Deferred _ | Completed _ | Settled _ | Blocked _)
  | Completed _, (Ready | Running _ | Deferred _ | Completed _ | Blocked _)
  | Settled _, (Ready | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _)
  | Blocked _, (Ready | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _) ->
    false
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

let invalidate_cached entry observed =
  ignore (Atomic.compare_and_set entry.cached observed None : bool)
;;

let publish_cached entry observed view =
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
  let* () = nonempty "partition judgment runtime_id" judgment.runtime_id in
  let* () = valid_time "partition judgment judged_at" judgment.judged_at in
  Keeper_board_attention_judgment.of_yojson
    (Keeper_board_attention_judgment.to_yojson judgment.verdict)
  |> Result.map ignore
;;

let validate_failure = Failure.validate_retryable
;;

let validate_blocked_reason = function
  | Candidate_membership_conflict detail ->
    nonempty "candidate membership conflict detail" detail
  | Durable_partition_invariant detail ->
    nonempty "durable partition invariant detail" detail
  | Judgment_blocked failure -> Failure.validate_blocked failure
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
                match candidate.status with
                | Candidate.Consumed _ -> Ok roots
                | Candidate.Pending _ | Candidate.Judged _ ->
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

let recover_for_process_start ~base_path ~keeper_name =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-process-start" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      match
        Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after:None
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
                  | Running _ ->
                    recovered + 1, { partition with state = Ready } :: latest
                  | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
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

let release_due_provider_retries ~now ~base_path ~keeper_name =
  let* () = valid_time "Provider retry release time" now in
  update ~base_path ~keeper_name (fun view ->
    let released =
      view_partitions view
      |> List.fold_left
           (fun acc partition ->
              match partition.state with
              | Deferred { failure; _ } ->
                (match Failure.retry_deadline failure with
                 | Some deadline when Float.compare now deadline >= 0 ->
                   { partition with state = Ready } :: acc
                 | Some _ | None -> acc)
              | Ready | Running _ | Completed _ | Settled _ | Blocked _ -> acc)
           []
      |> List.rev
    in
    Ok (released, List.length released))
;;

let next_provider_retry_deadline ~base_path ~keeper_name =
  let* view = read_view (path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  Ok
    (Id_map.fold
       (fun _ partition earliest ->
          match partition.state with
          | Deferred { failure; _ } ->
            (match earliest, Failure.retry_deadline failure with
             | None, deadline -> deadline
             | Some current, Some candidate
               when Float.compare candidate current < 0 -> Some candidate
             | Some _, Some _ | Some _, None -> earliest)
          | Ready | Running _ | Completed _ | Settled _ | Blocked _ -> earliest)
       view.by_id
       None)
;;

let claim_next ~now ~worker_epoch ~base_path ~keeper_name =
  let* () = valid_time "partition claim time" now in
  update ~base_path ~keeper_name (fun view ->
    match Ready_set.min_elt_opt view.ready with
    | None -> Ok ([], None)
    | Some selected_order ->
      (match Id_map.find_opt selected_order.partition_id view.by_id with
       | None -> Error ("ready index lost partition " ^ selected_order.partition_id)
       | Some selected ->
         let claimed =
           { selected with state = Running { worker_epoch; started_at = now } }
         in
         Ok ([ claimed ], Some claimed)))
;;

let recover_claim_after_lane_abort ~worker_epoch ~base_path ~partition =
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("partition not found during claim recovery: " ^ partition.partition_id)
    | Some current ->
      (match current.state with
       | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
         let released = { current with state = Ready } in
         Ok ([ released ], Claim_released released)
       | Running running ->
         Error
           (Printf.sprintf
              "claim recovery cannot revoke worker %s"
              (Worker_epoch.to_string running.worker_epoch))
       | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
         Ok ([], Claim_already_transitioned current)))
;;

let transition_running ~base_path ~partition ~worker_epoch state wrap =
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("Board attention partition not found: " ^ partition.partition_id)
    | Some current ->
      (match current.state with
       | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
         let updated = { current with state } in
         Ok ([ updated ], wrap updated)
       | Running running ->
         Error
           (Printf.sprintf
              "partition %s is owned by worker %s"
              partition.partition_id
              (Worker_epoch.to_string running.worker_epoch))
       | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
         Error ("partition is not Running: " ^ partition.partition_id)))
;;

let complete ~now ~worker_epoch ~base_path ~partition ~item =
  let* () = valid_time "partition completion time" now in
  let* () = validate_judgment item.judgment in
  if not (String.equal item.candidate_id partition.candidate_id)
  then Error "partition completion candidate identity mismatch"
  else
    transition_running
      ~base_path
      ~partition
      ~worker_epoch
      (Completed { item; completed_at = now })
      (fun row -> Partition_completed row)
;;

let defer ~now ~worker_epoch ~base_path ~partition failure =
  let* () = valid_time "partition defer time" now in
  let* () = validate_failure failure in
  transition_running
    ~base_path
    ~partition
    ~worker_epoch
    (Deferred { failure; deferred_at = now })
    (fun row -> Partition_deferred row)
;;

let block ~now ~worker_epoch ~base_path ~partition reason =
  let* () = valid_time "partition block time" now in
  let* () = validate_blocked_reason reason in
  transition_running
    ~base_path
    ~partition
    ~worker_epoch
    (Blocked { reason; blocked_at = now })
    (fun row -> Partition_blocked row)
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
    | Some ({ state = Completed _; _ } as current) ->
      let settled = { current with state = Settled { settled_at = now } } in
      Ok ([ settled ], settled)
    | Some current ->
      Error ("only Completed partition can settle: " ^ current.partition_id))
;;

module For_testing = struct
  let path = path
end
;;
