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
let field_n_before = "n_before"
let field_n_after = "n_after"
let field_publication_id = "publication_id"
let field_publication_state = "publication_state"
let ledger_schema_version = 3

let facts_digest facts =
  `List (List.map fact_to_json facts)
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
    ; field_episode, episode_to_json episode
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
      ~episode
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
      ~episode
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

let append_aborted
      ~masc_root
      ~publication_id
      ~keeper_id
      ~trace_id
      ~generation
      ~now
      ()
  =
  aborted_to_json
    ~publication_id
    ~keeper_id
    ~trace_id
    ~generation
    ~now
    ()
  |> append_json ~masc_root
;;

type pending_publication =
  { publication_id : string
  ; trace_id : string
  ; generation : int
  ; store_before_digest : string
  ; store_after_digest : string
  ; episode : episode
  }

type recovery_outcome =
  | No_pending_publication
  | Recovered_committed of string
  | Recovered_aborted of string

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

let pending_of_fields fields =
  match
    ( string_field field_publication_id fields
    , string_field field_trace_id fields
    , int_field field_generation fields
    , string_field field_store_before_digest fields
    , string_field field_store_after_digest fields
    , facts_field field_store_before fields
    , facts_field field_store_after fields
    , List.assoc_opt field_episode fields )
  with
  | ( Some publication_id
    , Some trace_id
    , Some generation
    , Some store_before_digest
    , Some store_after_digest
    , Some store_before
    , Some store_after
    , Some episode_json ) ->
    (match episode_of_json episode_json with
     | Some episode
       when String.equal store_before_digest (facts_digest store_before)
            && String.equal store_after_digest (facts_digest store_after) ->
       Ok
         { publication_id
         ; trace_id
         ; generation
         ; store_before_digest
         ; store_after_digest
         ; episode
         }
     | Some _ ->
       Error "prepared recognition publication has inconsistent fact digests"
     | None -> Error "prepared recognition publication has invalid episode payload")
  | _ -> Error "prepared recognition publication is missing recovery fields"
;;

let recover_pending ~masc_root ~keeper_id ~current_store ~now () =
  let pending = ref [] in
  let failure = ref None in
  let record_failure detail =
    match !failure with
    | None -> failure := Some detail
    | Some _ -> ()
  in
  let consume = function
    | Dated_jsonl.Malformed_json { path; line_number; detail } ->
      record_failure
        (Printf.sprintf
           "recognition ledger contains malformed JSON at %s%s: %s"
           path
           (match line_number with
            | Some line -> Printf.sprintf ":%d" line
            | None -> "")
           detail)
    | Dated_jsonl.Parsed (`Assoc fields) ->
      (match string_field field_keeper_id fields with
       | Some row_keeper when String.equal row_keeper keeper_id ->
         (match string_field field_publication_state fields with
          | Some "prepared" ->
            (match pending_of_fields fields with
             | Ok publication ->
               pending :=
                 publication
                 :: List.filter
                      (fun prior ->
                         not
                           (String.equal
                              prior.publication_id
                              publication.publication_id))
                      !pending
             | Error detail -> record_failure detail)
          | Some ("committed" | "aborted") ->
            (match string_field field_publication_id fields with
             | Some publication_id ->
               pending :=
                 List.filter
                   (fun publication ->
                      not (String.equal publication.publication_id publication_id))
                   !pending
             | None -> record_failure "terminal recognition row has no publication id")
          | Some state ->
            record_failure ("unknown recognition publication state: " ^ state)
          | None -> ())
       | Some _ | None -> ())
    | Dated_jsonl.Parsed _ ->
      record_failure "recognition ledger row is not an object"
  in
  try
    match Dated_jsonl.iter_all_entries_result (make_store ~masc_root ()) consume with
    | Error read_error -> Error (Dated_jsonl.read_error_to_string read_error)
    | Ok () ->
      (match !failure with
       | Some detail -> Error detail
       | None ->
         (match !pending with
          | [] -> Ok No_pending_publication
          | _ :: _ :: _ ->
            Error "multiple pending recognition publications violate serialization"
          | [ publication ] ->
            let current_digest = facts_digest current_store in
            if String.equal current_digest publication.store_before_digest
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
               | Ok () -> Ok (Recovered_aborted publication.publication_id)
               | Error detail ->
                 Error ("recognition abort marker write failed: " ^ detail))
            else if String.equal current_digest publication.store_after_digest
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
                     | Ok () -> Ok (Recovered_committed publication.publication_id)
                     | Error detail ->
                       Error ("recognition commit recovery failed: " ^ detail))))
            else
              Error
                "pending recognition publication matches neither canonical \
                 before nor after fact digest; repair is required"))
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
              | Ok () -> Ok ()))))
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
