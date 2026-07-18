(* See .mli. *)

module Candidate = Keeper_board_attention_candidate
module Id_map = Map.Make (String)
module Id_set = Set.Make (String)
module Context_map = Map.Make (String)

type completed_item =
  { candidate_id : string
  ; judgment : Candidate.judgment
  }

type state =
  | Ready
  | Running of
      { worker_epoch : string
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
      ; "worker_epoch", `String worker_epoch
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
    let* worker_epoch = string_json ~context:(context ^ ".worker_epoch") worker_epoch_json in
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

let durable_error_to_string = Fs_compat.durable_append_error_to_string

let read_locked ledger_path =
  match
    Fs_compat.update_private_file_durable_locked_result ledger_path (fun content ->
      None, parse_rows content)
  with
  | Error error -> Error (durable_error_to_string error)
  | Ok result -> result
;;

let load ~base_path ~keeper_name =
  let* partitions = read_locked (path ~base_path ~keeper_name) in
  match
    List.find_opt
      (fun partition -> not (String.equal partition.keeper_name keeper_name))
      partitions
  with
  | None -> Ok partitions
  | Some partition ->
    Error
      (Printf.sprintf
         "Board attention partition ledger identity mismatch expected=%s observed=%s partition=%s"
         keeper_name
         partition.keeper_name
         partition.partition_id)
;;

let update ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  try
    match
      Fs_compat.rewrite_private_file_durable_locked_result ledger_path (fun content ->
        match parse_rows content with
        | Error detail -> None, Error detail
        | Ok current ->
          (match
             List.find_opt
               (fun partition -> not (String.equal partition.keeper_name keeper_name))
               current
           with
           | Some partition ->
             ( None
             , Error
                 (Printf.sprintf
                    "Board attention partition ledger identity mismatch expected=%s observed=%s partition=%s"
                    keeper_name
                    partition.keeper_name
                    partition.partition_id) )
           | None ->
          (match decide current with
           | Error _ as error -> None, error
           | Ok (changed, updated, result) ->
             (if changed then Some (serialize updated) else None), Ok result)))
    with
    | Error error -> Error error
    | Ok result -> result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Error
      (Printf.sprintf
         "Board attention partition ledger update failed path=%s: %s"
         ledger_path
         (Printexc.to_string exn))
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

let is_live_leaf = function
  | Ready | Running _ | Deferred _ | Completed _ | Blocked _ -> true
  | Settled _ -> false
;;

let validate_live_membership partitions =
  List.fold_left
    (fun result partition ->
       let* owners = result in
       if not (is_live_leaf partition.state)
       then Ok owners
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
           (Ok owners)
           partition.candidate_ids)
    (Ok Id_map.empty)
    partitions
;;

let compare_candidate (left : Candidate.candidate) (right : Candidate.candidate) =
  match Float.compare left.recorded_at right.recorded_at with
  | 0 -> String.compare left.candidate_id right.candidate_id
  | ordering -> ordering
;;

let ensure_roots ~now ~base_path ~keeper_name candidates =
  update ~base_path ~keeper_name (fun current ->
    let* owners = validate_live_membership current in
    let* cohorts =
      candidates
      |> List.filter (fun candidate ->
        match candidate.Candidate.status with
        | Candidate.Pending _ -> not (Id_map.mem candidate.candidate_id owners)
        | Candidate.Judged _ | Candidate.Consumed _ -> false)
      |> List.sort compare_candidate
      |> List.fold_left
           (fun result candidate ->
              let* cohorts = result in
              let* context_key = Candidate.keeper_context_key candidate in
              let existing =
                Option.value ~default:[] (Context_map.find_opt context_key cohorts)
              in
              Ok (Context_map.add context_key (candidate :: existing) cohorts))
           (Ok Context_map.empty)
    in
    let existing_ids =
      List.fold_left
        (fun ids partition -> Id_set.add partition.partition_id ids)
        Id_set.empty
        current
    in
    let* roots =
      Context_map.bindings cohorts
      |> List.fold_left
           (fun result (context_key, reversed_candidates) ->
              let* roots = result in
              let candidate_ids =
                reversed_candidates
                |> List.rev
                |> List.map (fun candidate -> candidate.Candidate.candidate_id)
              in
              let partition_id = root_id ~keeper_name ~context_key candidate_ids in
              if Id_set.mem partition_id existing_ids
              then
                Error
                  (Printf.sprintf
                     "new pending cohort collides with existing partition %s"
                     partition_id)
              else
                Ok
                  ({ partition_id
                   ; keeper_name
                   ; context_key
                   ; candidate_ids
                   ; created_at = now
                   ; state = Ready
                   }
                   :: roots))
           (Ok [])
      |> Result.map List.rev
    in
    match roots with
    | [] -> Ok (false, current, current)
    | _ :: _ ->
      let updated = current @ roots in
      Ok (true, updated, updated))
;;

let recover_and_resume ~base_path ~keeper_name =
  update ~base_path ~keeper_name (fun current ->
    let recovered, changed, updated =
      List.fold_left
        (fun (recovered, changed, updated) partition ->
           match partition.state with
           | Running _ | Deferred _ ->
             recovered + 1, true, { partition with state = Ready } :: updated
           | Ready | Completed _ | Settled _ | Blocked _ ->
             recovered, changed, partition :: updated)
        (0, false, [])
        current
    in
    Ok (changed, List.rev updated, recovered))
;;

let compare_partition left right =
  match Float.compare left.created_at right.created_at with
  | 0 -> String.compare left.partition_id right.partition_id
  | ordering -> ordering
;;

let claim_next ~now ~worker_epoch ~base_path ~keeper_name =
  update ~base_path ~keeper_name (fun current ->
    let ready =
      current
      |> List.filter (fun partition -> partition.state = Ready)
      |> List.sort compare_partition
    in
    match ready with
    | [] -> Ok (false, current, None)
    | selected :: _ ->
      let claimed =
        { selected with state = Running { worker_epoch; started_at = now } }
      in
      let updated =
        List.map
          (fun partition ->
             if String.equal partition.partition_id selected.partition_id
             then claimed
             else partition)
          current
      in
      Ok (true, updated, Some claimed))
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

let with_running_partition ~worker_epoch ~partition current f =
  match
    List.find_opt
      (fun candidate -> String.equal candidate.partition_id partition.partition_id)
      current
  with
  | None -> Error ("partition not found: " ^ partition.partition_id)
  | Some persisted ->
    (match persisted.state with
     | Running running when String.equal running.worker_epoch worker_epoch ->
       f persisted
     | Running running ->
       Error
         (Printf.sprintf
            "partition %s is claimed by worker epoch %s"
            partition.partition_id
            running.worker_epoch)
     | Ready | Deferred _ | Completed _ | Settled _ | Blocked _ ->
       Error
         (Printf.sprintf
            "partition %s must be running, got %s"
            partition.partition_id
            (state_to_string persisted.state)))
;;

let replace_partition current updated_partition =
  List.map
    (fun partition ->
       if String.equal partition.partition_id updated_partition.partition_id
       then updated_partition
       else partition)
    current
;;

let complete ~now ~worker_epoch ~base_path ~partition ~items =
  let* items = ordered_completed_items partition items in
  update ~base_path ~keeper_name:partition.keeper_name (fun current ->
    with_running_partition ~worker_epoch ~partition current (fun persisted ->
      let completed = { persisted with state = Completed { items; completed_at = now } } in
      Ok (true, replace_partition current completed, Partition_completed completed)))
;;

let fail ~now ~worker_epoch ~base_path ~partition failure =
  update ~base_path ~keeper_name:partition.keeper_name (fun current ->
    with_running_partition ~worker_epoch ~partition current (fun persisted ->
      match failure.Candidate.kind with
      | Candidate.Partition_membership_conflict
      | Candidate.Durable_delivery_unavailable ->
        let blocked = { persisted with state = Blocked { failure; blocked_at = now } } in
        Ok (true, replace_partition current blocked, Partition_blocked blocked)
      | Candidate.Runtime_configuration_unavailable
        | Candidate.Prompt_contract_unavailable
        | Candidate.Provider_unavailable
        | Candidate.Response_contract_unavailable ->
        let deferred =
          { persisted with state = Deferred { failure; deferred_at = now } }
        in
        Ok (true, replace_partition current deferred, Partition_deferred deferred)))
;;

let completed ~base_path ~keeper_name =
  let* partitions = load ~base_path ~keeper_name in
  Ok
    (partitions
     |> List.filter (fun partition ->
       match partition.state with
       | Completed _ -> true
       | Ready | Running _ | Deferred _ | Settled _ | Blocked _ -> false)
     |> List.sort compare_partition)
;;

let settle_many ~now ~base_path ~keeper_name ~partition_ids =
  let* requested =
    List.fold_left
      (fun result partition_id ->
         let* ids = result in
         if Id_set.mem partition_id ids
         then Error ("duplicate partition settlement id: " ^ partition_id)
         else Ok (Id_set.add partition_id ids))
      (Ok Id_set.empty)
      partition_ids
  in
  update ~base_path ~keeper_name (fun current ->
    let* selected =
      List.fold_left
        (fun result partition_id ->
           let* selected = result in
           match
             List.find_opt
               (fun partition -> String.equal partition.partition_id partition_id)
               current
           with
           | None -> Error ("partition settlement target not found: " ^ partition_id)
           | Some ({ state = Completed _; _ } as partition)
           | Some ({ state = Settled _; _ } as partition) -> Ok (partition :: selected)
           | Some partition ->
             Error
               (Printf.sprintf
                  "partition %s cannot settle from %s"
                  partition_id
                  (state_to_string partition.state)))
        (Ok [])
        partition_ids
      |> Result.map List.rev
    in
    let updated =
      List.map
        (fun partition ->
           if Id_set.mem partition.partition_id requested
           then
             match partition.state with
             | Completed _ -> { partition with state = Settled { settled_at = now } }
             | Settled _ -> partition
             | Ready | Running _ | Deferred _ | Blocked _ -> partition
           else partition)
        current
    in
    let settled =
      List.map
        (fun selected_partition ->
           match
             List.find_opt
               (fun partition ->
                  String.equal partition.partition_id selected_partition.partition_id)
               updated
           with
           | Some partition -> partition
           | None -> selected_partition)
        selected
    in
    let changed =
      List.exists
        (fun partition ->
           Id_set.mem partition.partition_id requested
           && match partition.state with
              | Completed _ -> true
              | Ready | Running _ | Deferred _ | Settled _ | Blocked _ -> false)
        current
    in
    Ok (changed, updated, settled))
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
  ; partitions : t list
  ; read_errors : ledger_read_error list
  }

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
  let partitions, read_errors =
    List.fold_left
      (fun (partitions, errors) ledger_path ->
         match read_locked ledger_path with
         | Ok rows ->
           let ledger_segment =
             ledger_path
             |> Filename.basename
             |> fun name -> Filename.chop_suffix name ".jsonl"
           in
           (match
              List.find_opt
                (fun partition ->
                   let expected_segment =
                     Workspace_utils_backend_setup.sanitize_namespace_segment
                       partition.keeper_name
                   in
                   not (String.equal ledger_segment expected_segment))
                rows
            with
            | None -> List.rev_append rows partitions, errors
            | Some partition ->
              ( partitions
              , { ledger_path
                ; detail =
                    Printf.sprintf
                      "partition path identity mismatch keeper=%s partition=%s"
                      partition.keeper_name
                      partition.partition_id
                }
                :: errors ))
         | Error detail ->
           ( partitions
           , { ledger_path; detail }
             :: errors ))
      ([], discovery_errors)
      ledger_paths
  in
  { ledger_count = List.length ledger_paths
  ; partitions = List.rev partitions
  ; read_errors = List.rev read_errors
  }
;;

let count_state summary predicate =
  List.fold_left
    (fun count partition -> if predicate partition.state then count + 1 else count)
    0
    summary.partitions
;;

let pending_candidate_count summary =
  List.fold_left
    (fun count partition ->
       match partition.state with
       | Ready | Running _ | Deferred _ | Completed _ | Blocked _ ->
         count + List.length partition.candidate_ids
       | Settled _ -> count)
    0
    summary.partitions
;;

let status_reasons summary =
  []
  |> (fun reasons ->
    if count_state summary (function Blocked _ -> true | _ -> false) > 0
    then "blocked_partitions" :: reasons
    else reasons)
  |> (fun reasons ->
    if count_state summary (function Deferred _ -> true | _ -> false) > 0
    then "deferred_partitions" :: reasons
    else reasons)
  |> (fun reasons ->
    if summary.read_errors <> [] then "partition_ledger_read_errors" :: reasons else reasons)
  |> List.rev
;;

let operator_action_required summary = status_reasons summary <> []

let ledger_read_error_to_yojson error =
  `Assoc
    [ "ledger", `String error.ledger_path
    ; "error", `String error.detail
    ]
;;

let fleet_summary_schema = "masc.keeper_board_attention_partitions.fleet_summary.v1"

let fleet_summary_detail_fields summary =
  let count_state predicate =
    List.fold_left
      (fun count partition -> if predicate partition.state then count + 1 else count)
      0
      summary.partitions
  in
  let ready_count = count_state (function Ready -> true | _ -> false) in
  let running_count = count_state (function Running _ -> true | _ -> false) in
  let deferred_count = count_state (function Deferred _ -> true | _ -> false) in
  let completed_count = count_state (function Completed _ -> true | _ -> false) in
  let settled_count = count_state (function Settled _ -> true | _ -> false) in
  let blocked_count = count_state (function Blocked _ -> true | _ -> false) in
  let pending_candidate_count = pending_candidate_count summary in
  let blocked, deferred =
    List.fold_left
      (fun (blocked, deferred) partition ->
         match partition.state with
         | Blocked { failure; blocked_at } ->
           failure_detail_json partition failure "blocked_at" blocked_at :: blocked,
           deferred
         | Deferred { failure; deferred_at } ->
           blocked,
           failure_detail_json partition failure "deferred_at" deferred_at :: deferred
         | Ready | Running _ | Completed _ | Settled _ -> blocked, deferred)
      ([], [])
      summary.partitions
  in
  let read_error_count = List.length summary.read_errors in
  let keeper_names =
    summary.partitions
    |> List.map (fun partition -> partition.keeper_name)
    |> List.sort_uniq String.compare
  in
  [ "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", string_list_to_yojson keeper_names
    ; "ledger_count", `Int summary.ledger_count
    ; "partition_count", `Int (List.length summary.partitions)
    ; "pending_candidate_count", `Int pending_candidate_count
    ; "ready_count", `Int ready_count
    ; "running_count", `Int running_count
    ; "deferred_count", `Int deferred_count
    ; "completed_count", `Int completed_count
    ; "settled_count", `Int settled_count
    ; "blocked_count", `Int blocked_count
    ; "read_error_count", `Int read_error_count
    ; "read_errors", `List (List.map ledger_read_error_to_yojson summary.read_errors)
    ; "blocked", `List (List.rev blocked)
    ; "deferred", `List (List.rev deferred)
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

let fleet_summary_json ~base_path =
  fleet_summary ~base_path |> fleet_summary_to_yojson
;;

module For_testing = struct
  let path = path
end
;;
