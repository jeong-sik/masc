(* See .mli. *)

module Candidate = Keeper_board_attention_candidate
module Id_map = Map.Make (String)
module Id_set = Set.Make (String)

module Worker_epoch = struct
  type t = string

  let prefix = "board-attention-worker-"
  (* NDT-OK: UUID entropy is process-claim identity only. State transitions
     compare the opaque value for equality and never branch on random contents. *)
  let rng = Random.State.make_self_init () (* NDT-OK: identity entropy only *)
  let rng_mutex = Stdlib.Mutex.create ()

  let generate () =
    let uuid =
      Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.v4_gen rng ())
    in
    prefix ^ Uuidm.to_string uuid
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if
      String.length value = prefix_length + 36
      && String.equal (String.sub value 0 prefix_length) prefix
    then
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some _ -> Ok value
      | None -> Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
    else Error (Printf.sprintf "invalid Board attention worker epoch: %S" value)
  ;;

  let to_string value = value
  let equal = String.equal
end

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type state =
  | Ready
  | Running of
      { worker_epoch : Worker_epoch.t
      ; started_at : float
      }
  | Deferred of
      { failure : Candidate.retryable_failure
      ; deferred_at : float
      }
  | Completed of
      { items : completed_item list
      ; completed_at : float
      }
  | Settled of { settled_at : float }
  | Blocked of
      { failure : Candidate.retryable_failure
      ; blocked_at : float
      }

type t =
  { partition_id : string
  ; keeper_name : string
  ; context_key : string
  ; candidate_ids : string list
  ; created_at : float
  ; state : state
  }

type transition =
  | Partition_completed of t
  | Partition_deferred of t
  | Partition_blocked of t

type claim_recovery =
  | Claim_released of t
  | Claim_already_transitioned of t

let ( let* ) = Result.bind

let state_to_string = function
  | Ready -> "ready"
  | Running _ -> "running"
  | Deferred _ -> "deferred"
  | Completed _ -> "completed"
  | Settled _ -> "settled"
  | Blocked _ -> "blocked"
;;

let string_list_to_yojson values =
  `List (List.map (fun value -> `String value) values)
;;

let completed_item_to_yojson item =
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
      ; "failure", Candidate.retryable_failure_to_yojson failure
      ; "deferred_at", `Float deferred_at
      ]
  | Completed { items; completed_at } ->
    `Assoc
      [ "kind", `String "completed"
      ; "items", `List (List.map completed_item_to_yojson items)
      ; "completed_at", `Float completed_at
      ]
  | Settled { settled_at } ->
    `Assoc
      [ "kind", `String "settled"
      ; "settled_at", `Float settled_at
      ]
  | Blocked { failure; blocked_at } ->
    `Assoc
      [ "kind", `String "blocked"
      ; "failure", Candidate.retryable_failure_to_yojson failure
      ; "blocked_at", `Float blocked_at
      ]
;;

let to_yojson partition =
  `Assoc
    [ "partition_id", `String partition.partition_id
    ; "keeper_name", `String partition.keeper_name
    ; "context_key", `String partition.context_key
    ; "candidate_ids", string_list_to_yojson partition.candidate_ids
    ; "created_at", `Float partition.created_at
    ; "state", state_to_yojson partition.state
    ]
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

let assoc ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be an object")
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
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (context ^ " must be a number")
;;

let string_list_json ~context = function
  | `List values ->
    List.fold_left
      (fun result value ->
         let* values = result in
         let* value = string_json ~context value in
         Ok (value :: values))
      (Ok [])
      values
    |> Result.map List.rev
  | _ -> Error (context ^ " must be an array")
;;

let completed_item_of_yojson json =
  let context = "board attention partition completed item" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "candidate_id"; "judgment" ] fields in
  let* candidate_id_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_id_json in
  let* judgment_json = field ~context "judgment" fields in
  let* judgment = Candidate.judgment_of_yojson judgment_json in
  Ok { candidate_id; judgment }
;;

let completed_items_of_yojson = function
  | `List values ->
    List.fold_left
      (fun result value ->
         let* items = result in
         let* item = completed_item_of_yojson value in
         Ok (item :: items))
      (Ok [])
      values
    |> Result.map List.rev
  | _ -> Error "board attention partition completed items must be an array"
;;

let state_of_yojson json =
  let context = "board attention partition state" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "ready" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Ready
  | "running" ->
    let* () = exact_fields ~context [ "kind"; "worker_epoch"; "started_at" ] fields in
    let* worker_epoch_json = field ~context "worker_epoch" fields in
    let* worker_epoch_raw =
      string_json ~context:(context ^ ".worker_epoch") worker_epoch_json
    in
    let* worker_epoch = Worker_epoch.of_string worker_epoch_raw in
    let* started_at_json = field ~context "started_at" fields in
    let* started_at = float_json ~context:(context ^ ".started_at") started_at_json in
    Ok (Running { worker_epoch; started_at })
  | "deferred" ->
    let* () = exact_fields ~context [ "kind"; "failure"; "deferred_at" ] fields in
    let* failure_json = field ~context "failure" fields in
    let* failure = Candidate.retryable_failure_of_yojson failure_json in
    let* deferred_at_json = field ~context "deferred_at" fields in
    let* deferred_at = float_json ~context:(context ^ ".deferred_at") deferred_at_json in
    Ok (Deferred { failure; deferred_at })
  | "completed" ->
    let* () = exact_fields ~context [ "kind"; "items"; "completed_at" ] fields in
    let* items_json = field ~context "items" fields in
    let* items = completed_items_of_yojson items_json in
    let* completed_at_json = field ~context "completed_at" fields in
    let* completed_at = float_json ~context:(context ^ ".completed_at") completed_at_json in
    Ok (Completed { items; completed_at })
  | "settled" ->
    let* () = exact_fields ~context [ "kind"; "settled_at" ] fields in
    let* settled_at_json = field ~context "settled_at" fields in
    let* settled_at = float_json ~context:(context ^ ".settled_at") settled_at_json in
    Ok (Settled { settled_at })
  | "blocked" ->
    let* () = exact_fields ~context [ "kind"; "failure"; "blocked_at" ] fields in
    let* failure_json = field ~context "failure" fields in
    let* failure = Candidate.retryable_failure_of_yojson failure_json in
    let* blocked_at_json = field ~context "blocked_at" fields in
    let* blocked_at = float_json ~context:(context ^ ".blocked_at") blocked_at_json in
    Ok (Blocked { failure; blocked_at })
  | value -> Error (Printf.sprintf "unknown board attention partition state %S" value)
;;

let unique_nonempty_ids ~context ids =
  let rec loop seen = function
    | [] -> Ok ()
    | id :: rest ->
      if String.equal id ""
      then Error (context ^ " contains an empty candidate id")
      else if Id_set.mem id seen
      then Error (Printf.sprintf "%s contains duplicate candidate id %S" context id)
      else loop (Id_set.add id seen) rest
  in
  match ids with
  | [] -> Error (context ^ " must not be empty")
  | _ :: _ -> loop Id_set.empty ids
;;

let of_yojson json =
  let context = "board attention partition" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "partition_id"
      ; "keeper_name"
      ; "context_key"
      ; "candidate_ids"
      ; "created_at"
      ; "state"
      ]
      fields
  in
  let* partition_id_json = field ~context "partition_id" fields in
  let* partition_id = string_json ~context:(context ^ ".partition_id") partition_id_json in
  let* keeper_name_json = field ~context "keeper_name" fields in
  let* keeper_name = string_json ~context:(context ^ ".keeper_name") keeper_name_json in
  let* context_key_json = field ~context "context_key" fields in
  let* context_key = string_json ~context:(context ^ ".context_key") context_key_json in
  let* candidate_ids_json = field ~context "candidate_ids" fields in
  let* candidate_ids = string_list_json ~context:(context ^ ".candidate_ids") candidate_ids_json in
  let* () = unique_nonempty_ids ~context:(context ^ ".candidate_ids") candidate_ids in
  let* created_at_json = field ~context "created_at" fields in
  let* created_at = float_json ~context:(context ^ ".created_at") created_at_json in
  let* state_json = field ~context "state" fields in
  let* state = state_of_yojson state_json in
  Ok
    { partition_id
    ; keeper_name
    ; context_key
    ; candidate_ids
    ; created_at
    ; state
    }
;;

let partition_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "board_attention_partitions"
;;

let path ~base_path ~keeper_name =
  Filename.concat
    (partition_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let parse_rows content =
  let rec loop line_number acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      let line = String.trim line in
      if String.equal line ""
      then loop (line_number + 1) acc rest
      else
        (match Yojson.Safe.from_string line with
         | json ->
           (match of_yojson json with
            | Ok partition -> loop (line_number + 1) (partition :: acc) rest
            | Error detail ->
              Error
                (Printf.sprintf
                   "board attention partition ledger line %d: %s"
                   line_number
                   detail))
         | exception Yojson.Json_error detail ->
           Error
             (Printf.sprintf
                "board attention partition ledger line %d: invalid JSON: %s"
                line_number
                detail))
  in
  loop 1 [] (String.split_on_char '\n' content)
;;

let serialize partitions =
  partitions
  |> List.map (fun partition -> Yojson.Safe.to_string (to_yojson partition) ^ "\n")
  |> String.concat ""
;;

let framed values =
  values
  |> List.map (fun value -> Printf.sprintf "%d:%s" (String.length value) value)
  |> String.concat ""
;;

let digest_id prefix values =
  let digest = Digestif.SHA256.(digest_string (framed values) |> to_hex) in
  prefix ^ digest
;;

let root_id ~keeper_name ~context_key candidate_ids =
  digest_id "ba-root-" ("root" :: keeper_name :: context_key :: candidate_ids)
;;

let compare_partition left right =
  match Float.compare left.created_at right.created_at with
  | 0 -> String.compare left.partition_id right.partition_id
  | ordering -> ordering
;;

module Ready_order = struct
  type t =
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

type state_counts =
  { ready : int
  ; running : int
  ; deferred : int
  ; completed : int
  ; settled : int
  ; blocked : int
  ; pending_candidates : int
  }

type view =
  { cursor : Fs_compat.Private_jsonl_cursor.t
  ; by_id : t Id_map.t
  ; ready : Ready_set.t
  ; completed : Id_set.t
  ; live_candidate_owner : string Id_map.t
  ; blocked : t Id_map.t
  ; deferred : t Id_map.t
  ; keeper_names : Id_set.t
  ; counts : state_counts
  }

let empty_counts : state_counts =
  { ready = 0
  ; running = 0
  ; deferred = 0
  ; completed = 0
  ; settled = 0
  ; blocked = 0
  ; pending_candidates = 0
  }
;;

let empty_view cursor : view =
  { cursor
  ; by_id = Id_map.empty
  ; ready = Ready_set.empty
  ; completed = Id_set.empty
  ; live_candidate_owner = Id_map.empty
  ; blocked = Id_map.empty
  ; deferred = Id_map.empty
  ; keeper_names = Id_set.empty
  ; counts = empty_counts
  }
;;

let is_live_leaf = function
  | Ready | Running _ | Deferred _ | Completed _ | Blocked _ -> true
  | Settled _ -> false
;;

let adjust_counts delta partition (counts : state_counts) =
  let candidate_delta =
    if is_live_leaf partition.state
    then delta * List.length partition.candidate_ids
    else 0
  in
  let counts =
    { counts with pending_candidates = counts.pending_candidates + candidate_delta }
  in
  match partition.state with
  | Ready -> { counts with ready = counts.ready + delta }
  | Running _ -> { counts with running = counts.running + delta }
  | Deferred _ -> { counts with deferred = counts.deferred + delta }
  | Completed _ -> { counts with completed = counts.completed + delta }
  | Settled _ -> { counts with settled = counts.settled + delta }
  | Blocked _ -> { counts with blocked = counts.blocked + delta }
;;

let ready_order partition : Ready_order.t =
  { created_at = partition.created_at; partition_id = partition.partition_id }
;;

let remove_partition_indexes (view : view) partition =
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
  let blocked =
    match partition.state with
    | Blocked _ -> Id_map.remove partition.partition_id view.blocked
    | Ready | Running _ | Deferred _ | Completed _ | Settled _ -> view.blocked
  in
  let deferred =
    match partition.state with
    | Deferred _ -> Id_map.remove partition.partition_id view.deferred
    | Ready | Running _ | Completed _ | Settled _ | Blocked _ -> view.deferred
  in
  let live_candidate_owner =
    if is_live_leaf partition.state
    then
      List.fold_left
        (fun owners candidate_id -> Id_map.remove candidate_id owners)
        view.live_candidate_owner
        partition.candidate_ids
    else view.live_candidate_owner
  in
  { view with
    ready
  ; completed
  ; blocked
  ; deferred
  ; live_candidate_owner
  ; counts = adjust_counts (-1) partition view.counts
  }
;;

let add_live_candidate_owners (view : view) partition =
  if not (is_live_leaf partition.state)
  then Ok view.live_candidate_owner
  else
    List.fold_left
      (fun result candidate_id ->
         let* owners = result in
         match Id_map.find_opt candidate_id owners with
         | None -> Ok (Id_map.add candidate_id partition.partition_id owners)
         | Some existing ->
           Error
             (Printf.sprintf
                "candidate %s belongs to live partitions %s and %s"
                candidate_id
                existing
                partition.partition_id))
      (Ok view.live_candidate_owner)
      partition.candidate_ids
;;

let add_partition_indexes (view : view) partition =
  let* live_candidate_owner = add_live_candidate_owners view partition in
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
  let blocked =
    match partition.state with
    | Blocked _ -> Id_map.add partition.partition_id partition view.blocked
    | Ready | Running _ | Deferred _ | Completed _ | Settled _ -> view.blocked
  in
  let deferred =
    match partition.state with
    | Deferred _ -> Id_map.add partition.partition_id partition view.deferred
    | Ready | Running _ | Completed _ | Settled _ | Blocked _ -> view.deferred
  in
  Ok
    { view with
      by_id = Id_map.add partition.partition_id partition view.by_id
    ; ready
    ; completed
    ; live_candidate_owner
    ; blocked
    ; deferred
    ; keeper_names = Id_set.add partition.keeper_name view.keeper_names
    ; counts = adjust_counts 1 partition view.counts
    }
;;

let same_partition_identity left right =
  String.equal left.partition_id right.partition_id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.context_key right.context_key
  && left.candidate_ids = right.candidate_ids
  && Float.equal left.created_at right.created_at
;;

let legal_transition previous next =
  match previous, next with
  | Ready, Running _ -> true
  | Running _, (Ready | Completed _ | Deferred _ | Blocked _) -> true
  | Deferred _, Ready -> true
  | Completed _, Settled _ -> true
  | ( Ready
    , (Ready | Deferred _ | Completed _ | Settled _ | Blocked _) )
  | ( Running _
    , (Running _ | Settled _) )
  | ( Deferred _
    , (Running _ | Deferred _ | Completed _ | Settled _ | Blocked _) )
  | ( Completed _
    , (Ready | Running _ | Deferred _ | Completed _ | Blocked _) )
  | ( Settled _
    , (Ready | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _) )
  | ( Blocked _
    , (Ready | Running _ | Deferred _ | Completed _ | Settled _ | Blocked _) ) ->
    false
;;

let validate_root_identity partition =
  let expected =
    root_id
      ~keeper_name:partition.keeper_name
      ~context_key:partition.context_key
      partition.candidate_ids
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

type failure_disposition =
  | Defer_failure
  | Block_failure

let failure_disposition = function
  | Candidate.Partition_membership_conflict
    | Candidate.Durable_delivery_unavailable -> Block_failure
  | Candidate.Runtime_configuration_unavailable
    | Candidate.Prompt_contract_unavailable
    | Candidate.Provider_unavailable
    | Candidate.Response_contract_unavailable
    | Candidate.Durable_candidate_storage_unavailable -> Defer_failure
;;

let validate_state_payload partition =
  match partition.state with
  | Ready | Running _ | Settled _ -> Ok ()
  | Deferred { failure; _ } ->
    (match failure_disposition failure.Candidate.kind with
     | Defer_failure -> Ok ()
     | Block_failure ->
       Error
         (Printf.sprintf
            "partition %s defers terminal failure kind %s"
            partition.partition_id
            (Candidate.retryable_failure_kind_to_string failure.kind)))
  | Blocked { failure; _ } ->
    (match failure_disposition failure.Candidate.kind with
     | Block_failure -> Ok ()
     | Defer_failure ->
       Error
         (Printf.sprintf
            "partition %s blocks retryable failure kind %s"
            partition.partition_id
            (Candidate.retryable_failure_kind_to_string failure.kind)))
  | Completed { items; _ } ->
    let* returned_ids =
      List.fold_left
        (fun result item ->
           let* ids = result in
           if Id_set.mem item.candidate_id ids
           then
             Error
               (Printf.sprintf
                  "partition %s completed payload duplicates candidate %s"
                  partition.partition_id
                  item.candidate_id)
           else Ok (Id_set.add item.candidate_id ids))
        (Ok Id_set.empty)
        items
    in
    let requested_ids =
      List.fold_left
        (fun ids candidate_id -> Id_set.add candidate_id ids)
        Id_set.empty
        partition.candidate_ids
    in
    if not (Id_set.equal requested_ids returned_ids)
    then
      let missing = Id_set.diff requested_ids returned_ids |> Id_set.elements in
      let unknown = Id_set.diff returned_ids requested_ids |> Id_set.elements in
      Error
        (Printf.sprintf
           "partition %s completed payload identity mismatch missing=[%s] unknown=[%s]"
           partition.partition_id
           (String.concat "," missing)
           (String.concat "," unknown))
    else
      let ordered_ids = List.map (fun item -> item.candidate_id) items in
      if ordered_ids = partition.candidate_ids
      then Ok ()
      else
        Error
          (Printf.sprintf
             "partition %s completed payload order differs from immutable candidate order"
             partition.partition_id)
;;

let apply_row (view : view) partition =
  let* () = validate_root_identity partition in
  let* () = validate_state_payload partition in
  match Id_map.find_opt partition.partition_id view.by_id with
  | None -> add_partition_indexes view partition
  | Some previous ->
    if not (same_partition_identity previous partition)
    then
      Error
        (Printf.sprintf
           "partition %s changed immutable identity"
           partition.partition_id)
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
      let view = remove_partition_indexes view previous in
      add_partition_indexes view partition
;;

let apply_rows view rows =
  List.fold_left
    (fun result partition ->
       let* view = result in
       apply_row view partition)
    (Ok view)
    rows
;;

let view_partitions (view : view) =
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

let store_error error = Fs_compat.private_jsonl_transaction_error_to_string error

let invalidate_cached entry observed =
  (* See cache race contract: a failed CAS means a newer cursor owns the slot. *)
  ignore (Atomic.compare_and_set entry.cached observed None : bool)
;;

let publish_cached entry observed view =
  (* See cache race contract: publication is optional; [view] stays exact. *)
  ignore (Atomic.compare_and_set entry.cached observed (Some view) : bool)
;;

let read_view_blocking ledger_path =
  let entry = cache_entry ledger_path in
  let observed = Atomic.get entry.cached in
  let after = Option.map (fun view -> view.cursor) observed in
  match Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after with
  | Error error ->
    invalidate_cached entry observed;
    Error (store_error error)
  | Ok snapshot ->
    let* rows = parse_rows snapshot.bytes in
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
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      read_view_blocking ledger_path))
;;

let validate_keeper_identity ~keeper_name view =
  match
    Id_map.fold
      (fun _ partition mismatch ->
         match mismatch with
         | Some _ -> mismatch
         | None ->
           if String.equal partition.keeper_name keeper_name
           then None
           else Some partition)
      view.by_id
      None
  with
  | None -> Ok ()
  | Some partition ->
    Error
      (Printf.sprintf
         "Board attention partition ledger identity mismatch expected=%s observed=%s partition=%s"
         keeper_name
         partition.keeper_name
         partition.partition_id)
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
         with
         | Error error -> Error (store_error error)
         | Ok cursor ->
           Atomic.set entry.cached (Some { updated with cursor });
           Ok result)))
;;

let compare_candidate (left : Candidate.candidate) (right : Candidate.candidate) =
  match Float.compare left.recorded_at right.recorded_at with
  | 0 -> String.compare left.candidate_id right.candidate_id
  | ordering -> ordering
;;

let ensure_roots ~base_path ~keeper_name candidates =
  update ~base_path ~keeper_name (fun view ->
    let unassigned =
      candidates
      |> List.filter (fun candidate ->
        match candidate.Candidate.status with
        | Candidate.Pending _ ->
          not (Id_map.mem candidate.candidate_id view.live_candidate_owner)
        | Candidate.Judged _ | Candidate.Consumed _ -> false)
      |> List.sort compare_candidate
    in
    let* roots, _new_ids =
      List.fold_left
        (fun result candidate ->
           let* roots, new_ids = result in
           let* context_key = Candidate.keeper_context_key candidate in
           let candidate_ids = [ candidate.Candidate.candidate_id ] in
           let partition_id = root_id ~keeper_name ~context_key candidate_ids in
           match Id_map.find_opt partition_id view.by_id with
           | Some historical
             when String.equal historical.keeper_name keeper_name
                  && String.equal historical.context_key context_key
                  && historical.candidate_ids = candidate_ids ->
             Ok (roots, new_ids)
           | Some _ ->
             Error
               (Printf.sprintf
                  "new pending cohort collides with existing partition %s"
                  partition_id)
           | None when Id_set.mem partition_id new_ids ->
             Error
               (Printf.sprintf
                  "new pending cohort duplicates partition %s"
                  partition_id)
           | None ->
             Ok
               ( { partition_id
                 ; keeper_name
                 ; context_key
                 ; candidate_ids
                 ; created_at = candidate.recorded_at
                 ; state = Ready
                 }
                 :: roots
               , Id_set.add partition_id new_ids ))
        (Ok ([], Id_set.empty))
        unassigned
      |> Result.map (fun (roots, new_ids) -> List.rev roots, new_ids)
    in
    Ok (roots, roots))
;;

let recover_for_process_start ~base_path ~keeper_name =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-process-start" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      match Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after:None with
      | Error error -> Error (store_error error)
      | Ok snapshot ->
        let* rows = parse_rows snapshot.bytes in
        let* current = apply_rows (empty_view snapshot.cursor) rows in
        let* () = validate_keeper_identity ~keeper_name current in
        let recovered, latest =
          view_partitions current
          |> List.fold_left
               (fun (recovered, latest) partition ->
                  match partition.state with
                  | Running _ | Deferred _ ->
                    recovered + 1, { partition with state = Ready } :: latest
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
           with
           | Error error -> Error (store_error error)
           | Ok cursor ->
             let* compacted = apply_rows (empty_view cursor) latest in
             Atomic.set entry.cached (Some compacted);
             Ok recovered)))
;;

let claim_next ~now ~worker_epoch ~base_path ~keeper_name =
  update ~base_path ~keeper_name (fun view ->
    match Ready_set.min_elt_opt view.ready with
    | None -> Ok ([], None)
    | Some selected_order ->
      (match Id_map.find_opt selected_order.partition_id view.by_id with
       | None ->
         Error
           ("ready index lost partition " ^ selected_order.partition_id)
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
    | Some persisted ->
      (match persisted.state with
       | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
         let released = { persisted with state = Ready } in
         Ok ([ released ], Claim_released released)
       | Running running ->
         Error
           (Printf.sprintf
              "partition %s claim recovery cannot revoke worker epoch %s"
              partition.partition_id
              (Worker_epoch.to_string running.worker_epoch))
       | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
         Ok ([], Claim_already_transitioned persisted)))
;;

let requested_ids partition =
  List.fold_left
    (fun ids candidate_id -> Id_set.add candidate_id ids)
    Id_set.empty
    partition.candidate_ids
;;

let ordered_completed_items partition items =
  let* returned =
    List.fold_left
      (fun result item ->
         let* map = result in
         if Id_map.mem item.candidate_id map
         then Error (Printf.sprintf "duplicate completed candidate %s" item.candidate_id)
         else Ok (Id_map.add item.candidate_id item map))
      (Ok Id_map.empty)
      items
  in
  let requested = requested_ids partition in
  let returned_ids =
    Id_map.fold (fun candidate_id _ ids -> Id_set.add candidate_id ids) returned Id_set.empty
  in
  if not (Id_set.equal requested returned_ids)
  then
    let missing = Id_set.diff requested returned_ids |> Id_set.elements in
    let unknown = Id_set.diff returned_ids requested |> Id_set.elements in
    Error
      (Printf.sprintf
         "partition completion identity mismatch missing=[%s] unknown=[%s]"
         (String.concat "," missing)
         (String.concat "," unknown))
  else
    List.fold_left
      (fun result candidate_id ->
         let* ordered = result in
         match Id_map.find_opt candidate_id returned with
         | Some item -> Ok (item :: ordered)
         | None -> Error ("partition completion lost candidate " ^ candidate_id))
      (Ok [])
      partition.candidate_ids
    |> Result.map List.rev
;;

let with_running_partition ~worker_epoch ~partition view f =
  match Id_map.find_opt partition.partition_id view.by_id with
  | None -> Error ("partition not found: " ^ partition.partition_id)
  | Some persisted ->
    (match persisted.state with
     | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
       f persisted
     | Running running ->
       Error
         (Printf.sprintf
            "partition %s is claimed by worker epoch %s"
            partition.partition_id
            (Worker_epoch.to_string running.worker_epoch))
     | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
       Error
         (Printf.sprintf
            "partition %s must be running, got %s"
            partition.partition_id
            (state_to_string persisted.state)))
;;

let complete ~now ~worker_epoch ~base_path ~partition ~items =
  let* items = ordered_completed_items partition items in
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    with_running_partition ~worker_epoch ~partition view (fun persisted ->
      let completed = { persisted with state = Completed { items; completed_at = now } } in
      Ok ([ completed ], Partition_completed completed)))
;;

let fail ~now ~worker_epoch ~base_path ~partition failure =
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    with_running_partition ~worker_epoch ~partition view (fun persisted ->
      match failure_disposition failure.Candidate.kind with
      | Block_failure ->
        let blocked = { persisted with state = Blocked { failure; blocked_at = now } } in
        Ok ([ blocked ], Partition_blocked blocked)
      | Defer_failure ->
        let deferred =
          { persisted with state = Deferred { failure; deferred_at = now } }
        in
        Ok ([ deferred ], Partition_deferred deferred)))
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

let settle_many ~now ~base_path ~keeper_name ~partition_ids =
  let* (_requested : Id_set.t) =
    List.fold_left
      (fun result partition_id ->
         let* ids = result in
         if Id_set.mem partition_id ids
         then Error ("duplicate partition settlement id: " ^ partition_id)
         else Ok (Id_set.add partition_id ids))
      (Ok Id_set.empty)
      partition_ids
  in
  update ~base_path ~keeper_name (fun view ->
    let* rows, settled =
      List.fold_left
        (fun result partition_id ->
           let* rows, settled = result in
           match Id_map.find_opt partition_id view.by_id with
           | None -> Error ("partition settlement target not found: " ^ partition_id)
           | Some ({ state = Completed _; _ } as partition) ->
             let partition = { partition with state = Settled { settled_at = now } } in
             Ok (partition :: rows, partition :: settled)
           | Some ({ state = Settled _; _ } as partition) ->
             Ok (rows, partition :: settled)
           | Some partition ->
             Error
               (Printf.sprintf
                  "partition %s cannot settle from %s"
                  partition_id
                  (state_to_string partition.state)))
        (Ok ([], []))
        partition_ids
    in
    Ok (List.rev rows, List.rev settled))
;;

let failure_detail_json partition failure timestamp_name timestamp =
  `Assoc
    [ "partition_id", `String partition.partition_id
    ; "keeper_name", `String partition.keeper_name
    ; "candidate_count", `Int (List.length partition.candidate_ids)
    ; ( "failure_kind"
      , `String (Candidate.retryable_failure_kind_to_string failure.Candidate.kind) )
    ; "failure_detail", `String failure.detail
    ; timestamp_name, `Float timestamp
    ]
;;

type ledger_read_error =
  { ledger_path : string
  ; detail : string
  }

type fleet_summary =
  { ledger_count : int
  ; keeper_names : Id_set.t
  ; counts : state_counts
  ; blocked : t list
  ; deferred : t list
  ; read_errors : ledger_read_error list
  }

let add_counts (left : state_counts) (right : state_counts) : state_counts =
  { ready = left.ready + right.ready
  ; running = left.running + right.running
  ; deferred = left.deferred + right.deferred
  ; completed = left.completed + right.completed
  ; settled = left.settled + right.settled
  ; blocked = left.blocked + right.blocked
  ; pending_candidates = left.pending_candidates + right.pending_candidates
  }
;;

let fleet_summary ~base_path =
  let directory = partition_dir base_path in
  let ledger_paths, discovery_errors =
    try
      if not (Sys.file_exists directory)
      then [], []
      else if not (Sys.is_directory directory)
      then
        ( []
        , [ { ledger_path = directory
            ; detail = "partition ledger root is not a directory"
            }
          ] )
      else
        ( Sys.readdir directory
          |> Array.to_list
          |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
          |> List.sort String.compare
          |> List.map (Filename.concat directory)
        , [] )
    with
    | (Sys_error _ | Unix.Unix_error _) as exn ->
      ( []
      , [ { ledger_path = directory
          ; detail = Printexc.to_string exn
          }
        ] )
  in
  let counts, keeper_names, blocked, deferred, read_errors =
    List.fold_left
      (fun (counts, keeper_names, blocked, deferred, errors) ledger_path ->
         match read_view ledger_path with
         | Ok view ->
           let ledger_segment =
             ledger_path
             |> Filename.basename
             |> fun name -> Filename.chop_suffix name ".jsonl"
           in
           (match
              view.keeper_names
              |> Id_set.elements
              |> List.find_opt (fun keeper_name ->
                let expected_segment =
                  Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name
                in
                not (String.equal ledger_segment expected_segment))
            with
            | None ->
              ( add_counts counts view.counts
              , Id_set.union keeper_names view.keeper_names
              , List.rev_append (Id_map.bindings view.blocked |> List.map snd) blocked
              , List.rev_append (Id_map.bindings view.deferred |> List.map snd) deferred
              , errors )
            | Some keeper_name ->
              ( counts
              , keeper_names
              , blocked
              , deferred
              , { ledger_path
                ; detail =
                    Printf.sprintf
                      "partition path identity mismatch keeper=%s"
                      keeper_name
                }
                :: errors ))
         | Error detail ->
           ( counts
           , keeper_names
           , blocked
           , deferred
           , { ledger_path; detail }
             :: errors ))
      (empty_counts, Id_set.empty, [], [], discovery_errors)
      ledger_paths
  in
  { ledger_count = List.length ledger_paths
  ; keeper_names
  ; counts
  ; blocked = List.rev blocked
  ; deferred = List.rev deferred
  ; read_errors = List.rev read_errors
  }
;;

let pending_candidate_count (summary : fleet_summary) =
  summary.counts.pending_candidates
;;

let status_reasons (summary : fleet_summary) =
  []
  |> (fun reasons ->
    if summary.counts.blocked > 0
    then "blocked_partitions" :: reasons
    else reasons)
  |> (fun reasons ->
    if summary.counts.deferred > 0
    then "deferred_partitions" :: reasons
    else reasons)
  |> (fun reasons ->
    if summary.counts.completed > 0
    then "completed_delivery_pending" :: reasons
    else reasons)
  |> (fun reasons ->
    if summary.read_errors <> [] then "partition_ledger_read_errors" :: reasons else reasons)
  |> List.rev
;;

let operator_action_required (summary : fleet_summary) =
  status_reasons summary <> []
;;

let ledger_read_error_to_yojson error =
  `Assoc
    [ "ledger", `String error.ledger_path
    ; "error", `String error.detail
    ]
;;

let fleet_summary_schema = "masc.keeper_board_attention_partitions.fleet_summary.v1"

let fleet_summary_detail_fields (summary : fleet_summary) =
  let pending_candidate_count = pending_candidate_count summary in
  let blocked =
    List.map
      (fun partition ->
         match partition.state with
         | Blocked { failure; blocked_at } ->
           failure_detail_json partition failure "blocked_at" blocked_at
         | Ready | Running _ | Deferred _ | Completed _ | Settled _ ->
           invalid_arg "blocked partition index contains a non-blocked state")
      summary.blocked
  in
  let deferred =
    List.map
      (fun partition ->
         match partition.state with
         | Deferred { failure; deferred_at } ->
           failure_detail_json partition failure "deferred_at" deferred_at
         | Ready | Running _ | Completed _ | Settled _ | Blocked _ ->
           invalid_arg "deferred partition index contains a non-deferred state")
      summary.deferred
  in
  let read_error_count = List.length summary.read_errors in
  let keeper_names = Id_set.elements summary.keeper_names in
  let partition_count =
    summary.counts.ready
    + summary.counts.running
    + summary.counts.deferred
    + summary.counts.completed
    + summary.counts.settled
    + summary.counts.blocked
  in
  [ "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", string_list_to_yojson keeper_names
    ; "ledger_count", `Int summary.ledger_count
    ; "partition_count", `Int partition_count
    ; "pending_candidate_count", `Int pending_candidate_count
    ; "ready_count", `Int summary.counts.ready
    ; "running_count", `Int summary.counts.running
    ; "deferred_count", `Int summary.counts.deferred
    ; "completed_count", `Int summary.counts.completed
    ; "settled_count", `Int summary.counts.settled
    ; "blocked_count", `Int summary.counts.blocked
    ; "read_error_count", `Int read_error_count
    ; "read_errors", `List (List.map ledger_read_error_to_yojson summary.read_errors)
    ; "blocked", `List blocked
    ; "deferred", `List deferred
  ]
;;

let fleet_summary_fields summary =
  let operator_action_required = operator_action_required summary in
  [ "schema", `String fleet_summary_schema
  ; "status", `String (if operator_action_required then "degraded" else "ok")
  ; "operator_action_required", `Bool operator_action_required
  ; ( "status_reasons"
    , `List (List.map (fun reason -> `String reason) (status_reasons summary)) )
  ]
  @ fleet_summary_detail_fields summary
;;

let fleet_summary_to_yojson summary = `Assoc (fleet_summary_fields summary)

let empty_fleet_summary_detail_fields =
  fleet_summary_detail_fields
    { ledger_count = 0
    ; keeper_names = Id_set.empty
    ; counts = empty_counts
    ; blocked = []
    ; deferred = []
    ; read_errors = []
    }
;;

let fleet_summary_json ~base_path =
  fleet_summary ~base_path |> fleet_summary_to_yojson
;;

module For_testing = struct
  let path = path
end
;;
