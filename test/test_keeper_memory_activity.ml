open Alcotest
module Activity = Masc.Keeper_memory_activity
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Effects = Masc.Librarian_effects
module Log = Masc.Librarian_log
module Log_store = Masc.Librarian_log_store
module Turn_log = Masc.Keeper_turn_log

let fact claim =
  Memory.observed
    ~claim
    ~category:Memory.Constraint
    ~now:10.
    ~origin:{ kind = Memory.Authored; trace_id = "pass" }
;;

let old_a = fact "original a"
let old_b = fact "original b"
let successor = fact "combined claim"

let dummy_digest = Agent_core.Checkpoint_objects.digest_of_bytes "activity-test"

let dummy_log_id = Turn_log.Log_id.fresh ()
let dummy_mark : Turn_log.mark =
  { Turn_log.trace = ""
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }

let dummy_question_id =
  match
    Masc.Librarian_question_id.of_halves
      ~front:(String.make Masc.Librarian_question_id.half_length 'a')
      ~back:(String.make Masc.Librarian_question_id.half_length 'b')
  with
  | Some id -> id
  | None -> fail "question id"
;;

let make_commit
      ?(at = 20.)
      ?(revision = 2)
      ?(added = [])
      ?(touched = [])
      ?(removed = [])
      ()
  : Log.commit
  =
  { seq = revision
  ; at
  ; basis = dummy_digest
  ; after = dummy_digest
  ; revision
  ; cause =
      Log.Read
        { question = dummy_question_id
        ; shown = Log.With_memory
        ; slot = "slot-1"
        ; trace = "pass"
        ; missing = []
        }
  ; effects = { Effects.empty with added; touched; removed }
  ; turn_log = dummy_log_id
  ; turn_log_offset = 0
  ; covers_through = Log.Before_first
  ; covered = dummy_mark
  ; working_state = None
  }
;;

let project ?lookup_fact commit =
  match Activity.project_commit ?lookup_fact ~identity:"memory:alpha:42" commit with
  | Ok events -> events
  | Error reason -> fail reason
;;

let has_absorption events =
  List.exists (fun (event : Activity.event) -> event.kind = Activity.Absorbed) events
;;

let test_absorption () =
  let commit =
    make_commit
      ~added:[ successor ]
      ~removed:
        [ old_a, Effects.Merged_into (Memory.memory_id successor)
        ; old_b, Effects.Merged_into (Memory.memory_id successor)
        ]
      ()
  in
  let events = project commit in
  check int "one committed formation, no duplicate deletion" 1 (List.length events);
  let event = List.hd events in
  check bool "absorption" true (event.kind = Activity.Absorbed);
  check
    (list string)
    "exact original members"
    (List.sort String.compare [ Memory.memory_id old_a; Memory.memory_id old_b ])
    (List.map (fun (f : Activity.fact) -> f.memory_id) event.before
     |> List.sort String.compare);
  check
    (list string)
    "exact successor"
    [ Memory.memory_id successor ]
    (List.map (fun (f : Activity.fact) -> f.memory_id) event.after)
;;

let test_revision () =
  let commit =
    make_commit
      ~added:[ successor ]
      ~removed:[ old_a, Effects.Revised_into (Memory.memory_id successor) ]
      ()
  in
  let events = project commit in
  check int "one revision" 1 (List.length events);
  check bool "revision is not absorption" true ((List.hd events).kind = Activity.Revised)
;;

let test_supersede_and_retract () =
  let commit =
    make_commit
      ~added:[ successor ]
      ~removed:
        [ old_a, Effects.Superseded_by (Memory.memory_id successor)
        ; old_b, Effects.Retracted { by = Effects.Keeper; reason = "obsolete" }
        ]
      ()
  in
  let events = project commit in
  check int "revision plus retraction" 2 (List.length events);
  check bool "superseded becomes Revised" true
    (List.exists (fun (e : Activity.event) -> e.kind = Activity.Revised) events);
  check bool "retracted keeps reason" true
    (List.exists
       (fun (e : Activity.event) ->
          e.kind = Activity.Retracted && e.reason = Some "obsolete")
       events)
;;

let test_codec () =
  let commit =
    make_commit
      ~added:[ successor ]
      ~removed:[ old_a, Effects.Merged_into (Memory.memory_id successor) ]
      ()
  in
  let activity : Activity.t =
    { limit = 50
    ; journal_lines = 1
    ; events = project commit
    ; notes = [ "partial log" ]
    }
  in
  (match Activity.of_json (Activity.to_json activity) with
   | Error reason -> fail reason
   | Ok decoded ->
     check bool "identities, contents, lineage and notes round trip" true (decoded = activity));
  let change_event field value =
    match Activity.to_json activity with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, content) ->
              if key <> "events"
              then key, content
              else
                ( key
                , match content with
                  | `List (`Assoc event :: rest) ->
                    `List
                      (`Assoc ((field, value) :: List.remove_assoc field event) :: rest)
                  | _ -> fail "activity fixture has no event" ))
           fields)
    | _ -> fail "activity fixture is not an object"
  in
  check
    bool
    "unknown kind does not become an empty success"
    true
    (Result.is_error (Activity.of_json (change_event "kind" (`String "invented"))));
  let forged =
    `List
      [ `Assoc
          [ "memory_id", `String (Memory.memory_id old_a)
          ; "claim", `String "different bytes"
          ]
      ]
  in
  check
    bool
    "claim must match its exact identity"
    true
    (Result.is_error (Activity.of_json (change_event "before" forged)))
;;

let test_retained_successor () =
  let commit =
    make_commit
      ~removed:[ old_a, Effects.Merged_into (Memory.memory_id successor) ]
      ()
  in
  let lookup id =
    if String.equal id (Memory.memory_id successor) then Some successor else None
  in
  let events = project ~lookup_fact:lookup commit in
  check int "retained target creates only one formation event" 1 (List.length events);
  check bool "lookup resolves absorption" true (has_absorption events);
  let unknown = project commit in
  check
    bool
    "missing retained successor stays unresolved"
    true
    (List.exists
       (fun (event : Activity.event) -> event.kind = Activity.Relation_unavailable)
       unknown);
  check
    bool
    "unresolved successor is not a confirmed claim"
    true
    (List.exists
       (fun (event : Activity.event) ->
          List.exists
            (fun (f : Activity.fact) ->
               f.memory_id = Memory.memory_id successor && f.claim = None)
            event.after)
       unknown)
;;

let test_bad_clock () =
  List.iter
    (fun clock ->
       let commit = make_commit ~at:clock ~added:[ successor ] () in
       check
         bool
         "invalid clock refuses only this commit row"
         true
         (Result.is_error (Activity.project_commit ~identity:"memory:alpha:42" commit)))
    [ -1.; Float.nan; Float.infinity ]
;;

let test_read_from_memory_log () =
  let keepers_dir = Filename.temp_file "memory-activity-" ".dir" in
  Sys.remove keepers_dir;
  Unix.mkdir keepers_dir 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree keepers_dir) (fun () ->
    let log_path = Log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha" in
    let c1 = make_commit ~at:10. ~revision:1 ~added:[ old_a ] () in
    let c2 =
      make_commit
        ~at:25.
        ~revision:2
        ~touched:[ Memory.memory_id old_a ]
        ()
    in
    let append at_end commit =
      match Log_store.append ~path:log_path ~at_end (Log.Committed commit) with
      | Ok appended -> appended.new_end
      | Error _ -> fail "append commit log failed"
    in
    let e1 = append 0 c1 in
    let _e2 = append e1 c2 in
    let observed = Activity.read ~keepers_dir ~keeper_id:"alpha" ~limit:50 in
    check (list string) "no notes on clean commit log" [] observed.notes;
    check int "two commit log lines" 2 observed.journal_lines;
    check bool "contains Created and Reobserved events" true
      (List.exists (fun (e : Activity.event) -> e.kind = Activity.Created) observed.events
       && List.exists
            (fun (e : Activity.event) -> e.kind = Activity.Reobserved)
            observed.events))
;;

let () =
  run
    "Keeper memory activity"
    [ ( "committed lineage"
      , [ test_case "absorption retains endpoints" `Quick test_absorption
        ; test_case "revision differs from absorption" `Quick test_revision
        ; test_case "supersede and retract" `Quick test_supersede_and_retract
        ; test_case "read model codec" `Quick test_codec
        ; test_case "retained successor evidence" `Quick test_retained_successor
        ; test_case "bad observation clock" `Quick test_bad_clock
        ; test_case "read from memory commit log" `Quick test_read_from_memory_log
        ] )
    ]
;;
