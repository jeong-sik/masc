(* masc#26122 evidence: every applied librarian recognition pass persists its
   exact input (store snapshot the model saw), its output (the typed operation
   list), the per-operation structural dispositions, and the resulting store —
   as one row in a Dated_jsonl under masc_root. This is the anti-black-box
   guarantee: Before/After is always reconstructible from disk, unlike the
   compaction path whose plan/summary content was never persisted.

   The evidence write is part of recognition publication: a prepared row makes
   every later boundary recoverable, including the episode/event artifacts.
   Callers receive a typed failure and recall settles a stranded bundle before
   exposing it. Retention stays out of the hot path and is handled by server
   maintenance via [prune_older_than]. *)

open Keeper_memory_os_types

let base_dir ~masc_root = Filename.concat masc_root "librarian_recognition"

let field_schema_version = "schema_version"
let field_keeper_id = "keeper_id"
let field_trace_id = "trace_id"
let field_generation = "generation"
let field_ts = "ts"
let field_store_before = "store_before"
let field_store_after = "store_after"
let field_store_before_digest = "store_before_digest"
let field_store_after_digest = "store_after_digest"
let field_operations = "operations"
let field_dispositions = "dispositions"
let field_episode = "episode"
let field_facts_rewrite_required = "facts_rewrite_required"
let field_n_before = "n_before"
let field_n_after = "n_after"
let field_publication_id = "publication_id"
let field_publication_state = "publication_state"
let field_pending_publication = "pending_publication"
let field_prepared_logged = "prepared_logged"
let ledger_schema_version = 3

let facts_digest facts =
  `List (List.map fact_to_json facts)
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let publication_id_from_json
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations_json
      ~dispositions_json
      ~store_after
      ~episode
      ~facts_rewrite_required
  =
  `Assoc
    [ field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_generation, `Int generation
    ; field_store_before, `List (List.map fact_to_json store_before)
    ; field_operations, operations_json
    ; field_dispositions, dispositions_json
    ; field_store_after, `List (List.map fact_to_json store_after)
    ; field_episode, episode_to_json episode
    ; field_facts_rewrite_required, `Bool facts_rewrite_required
    ]
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations
      ~dispositions
      ~store_after
      ~episode
      ~facts_rewrite_required
  =
  publication_id_from_json
    ~keeper_id
    ~trace_id
    ~generation
    ~store_before
    ~operations_json:
      (`List (List.map Keeper_librarian_recognition.operation_to_json operations))
    ~dispositions_json:
      (`List
         (List.map
            (fun disposition ->
               `String
                 (Keeper_librarian_recognition.disposition_label disposition))
            dispositions))
    ~store_after
    ~episode
    ~facts_rewrite_required
;;

let prepared_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations
      ~dispositions
      ~store_after
      ~episode
      ~facts_rewrite_required
      ~now
      ()
  : Yojson.Safe.t
  =
  `Assoc
    [ field_schema_version, `Int ledger_schema_version
    ; field_publication_id, `String publication_id
    ; field_publication_state, `String "prepared"
    ; field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_generation, `Int generation
    ; field_ts, `Float now
    ; field_n_before, `Int (List.length store_before)
    ; field_n_after, `Int (List.length store_after)
    ; field_store_before_digest, `String (facts_digest store_before)
    ; field_store_after_digest, `String (facts_digest store_after)
    ; ( field_operations
      , `List (List.map Keeper_librarian_recognition.operation_to_json operations) )
    ; ( field_dispositions
      , `List
          (List.map
             (fun d ->
                `String (Keeper_librarian_recognition.disposition_label d))
             dispositions) )
    ; field_store_before, `List (List.map fact_to_json store_before)
    ; field_store_after, `List (List.map fact_to_json store_after)
    ; field_episode, episode_to_json episode
    ; field_facts_rewrite_required, `Bool facts_rewrite_required
    ]
;;

let committed_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
  =
  `Assoc
    [ field_schema_version, `Int ledger_schema_version
    ; field_publication_id, `String publication_id
    ; field_publication_state, `String "committed"
    ; field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_generation, `Int generation
    ; field_ts, `Float now
    ]
;;

let aborted_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
  =
  `Assoc
    [ field_schema_version, `Int ledger_schema_version
    ; field_publication_id, `String publication_id
    ; field_publication_state, `String "aborted"
    ; field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_generation, `Int generation
    ; field_ts, `Float now
    ]
;;

let make_store ~masc_root () = Dated_jsonl.create ~base_dir:(base_dir ~masc_root) ()

let pending_path ~masc_root ~keeper_id =
  Keeper_memory_os_io.recognition_pending_path_for_masc_root
    ~masc_root
    ~keeper_id
;;

let append_json ~masc_root entry =
  try
    let dated =
      Jsonl_writer.dated_path_now ~base_dir:(base_dir ~masc_root)
    in
    let suffix = Yojson.Safe.to_string entry ^ "\n" in
    match
      Fs_compat.append_private_jsonl_durable_locked_result dated.path suffix
    with
    | Fs_compat.Private_file_succeeded () -> Ok ()
    | Fs_compat.Private_file_succeeded_with_cleanup_failure
        { value = (); cleanup_failure } ->
      Log.Keeper.warn
        "librarian recognition audit append committed with cleanup failure: %s"
        (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
      Ok ()
    | Fs_compat.Private_file_failed error ->
      Error (Fs_compat.private_jsonl_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure
        { error; cleanup_failure } ->
      Error
        (Printf.sprintf
           "%s; cleanup failure: %s"
           (Fs_compat.private_jsonl_append_error_to_string error)
           (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)
;;

let pending_marker_to_json ~prepared ~prepared_logged =
  `Assoc
    [ field_pending_publication, prepared
    ; field_prepared_logged, `Bool prepared_logged
    ]
;;

let save_pending_marker ~masc_root ~keeper_id ~prepared ~prepared_logged =
  let path = pending_path ~masc_root ~keeper_id in
  match
    Keeper_fs.save_json_durable_atomic
      ~ownership_root:masc_root
      ~pretty:false
      path
      (pending_marker_to_json ~prepared ~prepared_logged)
  with
  | Ok () -> Ok ()
  | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
;;

type terminal_write_outcome =
  | Terminal_durable
  | Terminal_durable_marker_clear_uncertain of string

let terminal_outcome_of_remove_result = function
  | Ok () -> Ok Terminal_durable
  | Error ({ Keeper_fs.removed = true; _ } as error) ->
    Ok
      (Terminal_durable_marker_clear_uncertain
         (Keeper_fs.durable_remove_error_to_string error))
  | Error ({ Keeper_fs.removed = false; _ } as error) ->
    Error (Keeper_fs.durable_remove_error_to_string error)
;;

let clear_pending_marker ~masc_root ~keeper_id ~publication_id =
  let path = pending_path ~masc_root ~keeper_id in
  try
    if not (Sys.file_exists path)
    then Ok Terminal_durable
    else (
      let channel = open_in_bin path in
      let json =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
             really_input_string channel (in_channel_length channel)
             |> Yojson.Safe.from_string)
      in
      match json with
      | `Assoc marker_fields ->
        (match List.assoc_opt field_pending_publication marker_fields with
         | Some (`Assoc prepared_fields) ->
           (match List.assoc_opt field_publication_id prepared_fields with
            | Some (`String stored_id) when String.equal stored_id publication_id ->
              Keeper_fs.remove_file_durable ~ownership_root:masc_root path
              |> terminal_outcome_of_remove_result
            | Some (`String _) -> Error "pending recognition publication id changed"
            | Some _ | None -> Error "pending recognition publication has no id")
         | Some _ | None -> Error "pending recognition marker has no prepared payload")
      | _ -> Error "pending recognition marker is not an object")
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let append_prepared
      ~masc_root
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations
      ~dispositions
      ~store_after
      ~episode
      ~facts_rewrite_required
      ~now
      ()
  =
  let entry =
    prepared_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations
      ~dispositions
      ~store_after
      ~episode
      ~facts_rewrite_required
      ~now
      ()
  in
  let path = pending_path ~masc_root ~keeper_id in
  if Sys.file_exists path
  then Error "a pending recognition publication already exists"
  else
    match
      save_pending_marker
        ~masc_root
        ~keeper_id
        ~prepared:entry
        ~prepared_logged:false
    with
    | Error _ as error -> error
    | Ok () ->
      (match append_json ~masc_root entry with
       | Error _ as error -> error
       | Ok () ->
         save_pending_marker
           ~masc_root
           ~keeper_id
           ~prepared:entry
           ~prepared_logged:true)
;;

let append_committed
      ~masc_root
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
  =
  match
    committed_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
    |> append_json ~masc_root
  with
  | Error _ as error -> error
  | Ok () -> clear_pending_marker ~masc_root ~keeper_id ~publication_id
;;

let append_aborted
      ~masc_root
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
  =
  match
    aborted_to_json
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
    |> append_json ~masc_root
  with
  | Error _ as error -> error
  | Ok () -> clear_pending_marker ~masc_root ~keeper_id ~publication_id
;;

type pending_publication =
  { publication_id : string
  ; trace_id : string
  ; generation : int
  ; store_before_digest : string
  ; store_after_digest : string
  ; episode : episode
  ; facts_rewrite_required : bool
  ; prepared_json : Yojson.Safe.t
  ; prepared_logged : bool
  }

type recovery_outcome =
  | No_pending_publication
  | Recovered_committed of string * terminal_write_outcome
  | Recovered_aborted of string * terminal_write_outcome

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

let int_field key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | Some _ | None -> None
;;

let bool_field key fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Some value
  | Some _ | None -> None
;;

let facts_field key fields =
  let rec decode acc = function
    | [] -> Some (List.rev acc)
    | json :: rest ->
      (match fact_of_json json with
       | Some fact -> decode (fact :: acc) rest
       | None -> None)
  in
  match List.assoc_opt key fields with
  | Some (`List values) -> decode [] values
  | Some _ | None -> None
;;

let pending_of_fields ~keeper_id ~prepared_json ~prepared_logged fields =
  match
    ( string_field field_publication_id fields
    , string_field field_trace_id fields
    , int_field field_generation fields
    , string_field field_store_before_digest fields
    , string_field field_store_after_digest fields
    , facts_field field_store_before fields
    , facts_field field_store_after fields
    , List.assoc_opt field_operations fields
    , List.assoc_opt field_dispositions fields
    , bool_field field_facts_rewrite_required fields
    , List.assoc_opt field_episode fields )
  with
  | ( Some publication_id
    , Some trace_id
    , Some generation
    , Some store_before_digest
    , Some store_after_digest
    , Some store_before
    , Some store_after
    , Some (`List _ as operations_json)
    , Some (`List _ as dispositions_json)
    , Some facts_rewrite_required
    , Some episode_json ) ->
    (match episode_of_json episode_json with
     | Some episode
       when String.equal store_before_digest (facts_digest store_before)
            && String.equal store_after_digest (facts_digest store_after)
            && int_field field_schema_version fields = Some ledger_schema_version
            && String.equal episode.trace_id trace_id
            && Int.equal episode.generation generation
            && (facts_rewrite_required
                || String.equal store_before_digest store_after_digest)
            && String.equal
                 publication_id
                 (publication_id_from_json
                    ~keeper_id
                    ~trace_id
                    ~generation
                    ~store_before
                    ~operations_json
                    ~dispositions_json
                    ~store_after
                    ~episode
                    ~facts_rewrite_required) ->
       Ok
         { publication_id
         ; trace_id
         ; generation
         ; store_before_digest
         ; store_after_digest
         ; episode
         ; facts_rewrite_required
         ; prepared_json
         ; prepared_logged
         }
     | Some _ ->
       Error "prepared recognition publication failed payload integrity checks"
     | None -> Error "prepared recognition publication has invalid episode payload")
  | _ -> Error "prepared recognition publication is missing recovery fields"
;;

let load_pending_marker ~masc_root ~keeper_id =
  let path = pending_path ~masc_root ~keeper_id in
  if not (Sys.file_exists path)
  then Ok None
  else
    try
      let channel = open_in_bin path in
      let json =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
             really_input_string channel (in_channel_length channel)
             |> Yojson.Safe.from_string)
      in
      match json with
      | `Assoc marker_fields ->
        (match
           ( List.assoc_opt field_pending_publication marker_fields
           , bool_field field_prepared_logged marker_fields )
         with
         | Some (`Assoc prepared_fields as prepared_json), Some prepared_logged ->
           (match
              ( string_field field_keeper_id prepared_fields
              , string_field field_publication_state prepared_fields )
            with
            | Some row_keeper, Some "prepared"
              when String.equal row_keeper keeper_id ->
              Result.map
                (fun publication -> Some publication)
                (pending_of_fields
                   ~keeper_id
                   ~prepared_json
                   ~prepared_logged
                   prepared_fields)
            | Some _, Some _ | Some _, None | None, _ ->
              Error "pending recognition marker ownership/state mismatch")
         | Some _, Some _ | Some _, None | None, _ ->
           Error "pending recognition marker is missing typed fields")
      | _ -> Error "pending recognition marker is not an object"
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
;;

let recover_pending ~masc_root ~keeper_id ~current_store ~now () =
  try
    match load_pending_marker ~masc_root ~keeper_id with
    | Error _ as error -> error
    | Ok None -> Ok No_pending_publication
    | Ok (Some publication) ->
      (* The dated audit retention sweep can remove an old prepared row while
         its O(1) pending marker remains. Reassert the exact prepared payload on
         every recovery before writing a terminal state. At-least-once physical
         duplicates are collapsed by [read_all_canonical]. *)
      let prepared_ready =
        match append_json ~masc_root publication.prepared_json with
        | Error _ as error -> error
        | Ok () ->
          if publication.prepared_logged
          then Ok ()
          else
            save_pending_marker
              ~masc_root
              ~keeper_id
              ~prepared:publication.prepared_json
              ~prepared_logged:true
      in
      (match prepared_ready with
       | Error detail ->
         Error ("recognition prepared evidence recovery failed: " ^ detail)
       | Ok () ->
            let current_digest = facts_digest current_store in
            let before_matches =
              String.equal current_digest publication.store_before_digest
            in
            let after_matches =
              String.equal current_digest publication.store_after_digest
            in
            if publication.facts_rewrite_required && before_matches
            then
              (match
                 append_aborted
                   ~masc_root
                   ~publication_id:publication.publication_id
                   ~keeper_id
                   ~trace_id:publication.trace_id
                   ~generation:publication.generation
                   ~now
                   ()
               with
               | Ok outcome ->
                 Ok (Recovered_aborted (publication.publication_id, outcome))
               | Error detail ->
                 Error ("recognition abort marker write failed: " ^ detail))
            else if
              after_matches
              && ((not publication.facts_rewrite_required)
                  || not before_matches)
            then
              (match
                 Keeper_memory_os_io.ensure_recognition_episode
                   ~keeper_id
                   ~publication_id:publication.publication_id
                   publication.episode
               with
               | Error detail ->
                 Error ("recognition episode recovery failed: " ^ detail)
               | Ok () ->
                 (match
                    Keeper_memory_os_io.ensure_recognition_event
                      ~keeper_id
                      ~publication_id:publication.publication_id
                      publication.episode
                  with
                  | Error detail ->
                    Error ("recognition event recovery failed: " ^ detail)
                  | Ok () ->
                    (match
                       append_committed
                         ~masc_root
                         ~publication_id:publication.publication_id
                         ~keeper_id
                         ~trace_id:publication.trace_id
                         ~generation:publication.generation
                         ~now
                         ()
                     with
                     | Ok outcome ->
                       Ok
                         (Recovered_committed
                            (publication.publication_id, outcome))
                     | Error detail ->
                       Error ("recognition commit recovery failed: " ^ detail))))
            else
              Error
                "pending recognition publication matches neither canonical \
                 transition state nor its publication mode; repair is required")
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

type publication_failure =
  | Prepare_failed of string
  | Rewrite_failed of string
  | Episode_failed of string
  | Event_failed of string
  | Commit_failed of string

let publish ~prepare ~rewrite ~episode ~event ~commit =
  match prepare () with
  | Error detail -> Error (Prepare_failed detail)
  | Ok () ->
    (match rewrite () with
     | Error detail -> Error (Rewrite_failed detail)
     | Ok () ->
       (match episode () with
        | Error detail -> Error (Episode_failed detail)
        | Ok () ->
          (match event () with
           | Error detail -> Error (Event_failed detail)
           | Ok () ->
             (match commit () with
              | Error detail -> Error (Commit_failed detail)
              | Ok outcome -> Ok outcome))))
;;

let read_all_canonical ~masc_root =
  let seen = Hashtbl.create 128 in
  let rows = ref [] in
  let decode_key = function
    | `Assoc fields ->
      (match
         string_field field_publication_id fields,
         string_field field_publication_state fields
       with
       | Some publication_id, Some publication_state ->
         Ok (publication_id, publication_state)
       | None, _ | _, None ->
         Error "recognition audit row is missing publication identity/state")
    | _ -> Error "recognition audit row is not an object"
  in
  let row_error = ref None in
  match
    Dated_jsonl.iter_all_entries_result
      (make_store ~masc_root ())
      (fun entry ->
         match !row_error, entry with
         | Some _, _ -> ()
         | None, Dated_jsonl.Malformed_json { path; line_number; detail } ->
           row_error
           := Some
                (Printf.sprintf
                   "%s%s: malformed recognition audit JSON: %s"
                   path
                   (match line_number with
                    | None -> ""
                    | Some line -> Printf.sprintf ":%d" line)
                   detail)
         | None, Dated_jsonl.Parsed json ->
           (match decode_key json with
            | Error detail -> row_error := Some detail
            | Ok key ->
              if not (Hashtbl.mem seen key)
              then (
                Hashtbl.add seen key ();
                rows := json :: !rows)))
  with
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
  | Ok () ->
    (match !row_error with
     | Some detail -> Error detail
     | None -> Ok (List.rev !rows))
;;

module For_testing = struct
  let terminal_outcome_of_remove_result = terminal_outcome_of_remove_result
end

let prune_older_than ~masc_root ~retention_days =
  try Ok (Dated_jsonl.prune (make_store ~masc_root ()) ~days:retention_days) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "librarian_recognition_ledger: failed to prune %s: %s"
      (base_dir ~masc_root)
      (Printexc.to_string exn);
    Error ()
;;
