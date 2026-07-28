(* masc#26122 evidence: every applied librarian recognition pass persists its
   exact input (store snapshot the model saw), its output (the typed operation
   list), the per-operation structural dispositions, and the resulting store —
   as one row in a Dated_jsonl under masc_root. This is the anti-black-box
   guarantee: Before/After is always reconstructible from disk, unlike the
   compaction path whose plan/summary content was never persisted.

   The evidence write is part of recognition publication: callers must receive
   a typed failure and leave the fact snapshot untouched when it cannot be
   made durable. Retention stays out of the hot path and is handled by server
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
let field_operations = "operations"
let field_dispositions = "dispositions"
let field_n_before = "n_before"
let field_n_after = "n_after"
let field_publication_id = "publication_id"
let field_publication_state = "publication_state"
let ledger_schema_version = 2

let publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~store_before
      ~operations
      ~dispositions
      ~store_after
  =
  `Assoc
    [ field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_generation, `Int generation
    ; field_store_before, `List (List.map fact_to_json store_before)
    ; field_operations
      , `List (List.map Keeper_librarian_recognition.operation_to_json operations)
    ; field_dispositions
      , `List
          (List.map
             (fun disposition ->
                `String
                  (Keeper_librarian_recognition.disposition_label disposition))
             dispositions)
    ; field_store_after, `List (List.map fact_to_json store_after)
    ]
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
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

let make_store ~masc_root () = Dated_jsonl.create ~base_dir:(base_dir ~masc_root) ()

let append_json ~masc_root entry =
  try
    Dated_jsonl.append (make_store ~masc_root ()) entry;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
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
      ~now
      ()
  in
  append_json ~masc_root entry
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
  committed_to_json
    ~publication_id
    ~keeper_id
    ~trace_id
    ~generation
    ~now
    ()
  |> append_json ~masc_root
;;

type publication_failure =
  | Prepare_failed of string
  | Rewrite_failed of string
  | Commit_failed of string

let publish ~prepare ~rewrite ~commit =
  match prepare () with
  | Error detail -> Error (Prepare_failed detail)
  | Ok () ->
    (match rewrite () with
     | Error detail -> Error (Rewrite_failed detail)
     | Ok () ->
       (match commit () with
        | Error detail -> Error (Commit_failed detail)
        | Ok () -> Ok ()))
;;

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
