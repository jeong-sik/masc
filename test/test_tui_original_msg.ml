(* Original Task inspection's answers are [Masc_tui_original_results.msg] and
   travel in [async_msg] as [Original_msg] (#48617). Every answer is a read
   that never waits for input. An awaited answer lands while its inspector is
   current. When the inspector is no longer current, the answer does not land
   and the inspection's reads are suspended. An answer the inspection no
   longer waits on changes nothing. Evidence answers are only classified here:
   choosing a verification to read needs a Task or history page naming one. *)

module Protocol = Masc_tui_async_protocol
module Original = Masc_tui_original_results
module Read = Masc_tui_original_task_read
module Fetched = Masc_tui_fetched
module Types = Masc_tui_types
module Asks = Masc.Tui_decode_asks

let fresh () = Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. ()

let base_path = "/workspace/original"
let masc_root = "/workspace/original/.masc"

let workspace () =
  let json =
    `Assoc
      [ ( "paths"
        , `Assoc
            [ ("effective_base_path", `String base_path)
            ; ("effective_masc_root", `String masc_root) ] )
      ; ("startup", `Assoc [ ("state_ready", `Bool true) ]) ]
  in
  match Masc.Tui_decode.decode_server_identity json with
  | Ok identity -> identity
  | Error detail -> Alcotest.fail detail

let answer_identity () =
  let json =
    `Assoc
      [ ("workspace", `Assoc [ ("base_path", `String base_path); ("masc_root", `String masc_root) ])
      ; ("state_ready", `Bool true)
      ; ("keeper", `String "alpha")
      ; ("answer_progress_for", `String "ask-1")
      ; ( "answer_progress"
        , `Assoc
            [ ("state", `String "started")
            ; ("answered_at", `Float 200.)
            ; ("stimulus_id", `String "stimulus-1") ] ) ]
  in
  match
    Asks.decode_ask_followup_event ~expected_base_path:base_path ~expected_masc_root:masc_root
      ~keeper_name:"alpha" ~ask_id:"ask-1" json
  with
  | Ok (Asks.Ask_followup_started identity) -> identity
  | Ok (Asks.Ask_followup_source _ | Asks.Ask_followup_completed _) ->
      Alcotest.fail "expected the answer's start"
  | Error detail -> Alcotest.fail detail

(* An answered Ask's source names its Task, so a Task or history read starts
   without a creation receipt. The inspection that holds it belongs to a
   created Task, whose inspector stays current while the composer keeps its
   target. Production pairs a created Task with its own creation source; the
   answers below read only the source's Task link. *)
let open_inspection (state : Types.state) =
  let source =
    match
      Read.create_ask ~keeper:"alpha" ~ask_id:"ask-1" ~workspace:(workspace ())
        ~identity:(answer_identity ()) ~task:(Asks.Ask_task_missing "task-1")
    with
    | Ok source -> source
    | Error _ -> Alcotest.fail "the Ask's Task link opened no source"
  in
  let intent =
    { Masc_tui_task_dispatch.request_id = "request-1"
    ; keeper = "alpha"
    ; title = "title"
    ; body = "body"
    ; original = "original"
    ; workspace = None }
  in
  let owner =
    Types.Created_task_owner
      { Types.tdr_dispatch = Masc_tui_task_dispatch.create intent
      ; tdr_authority = state.workspace_authority
      ; tdr_editor = Masc_tui_message_input.revision (Masc_tui_message_input.create ())
      ; tdr_editor_keeper = None
      ; tdr_inspection = source
      ; tdr_inspection_pending = None }
  in
  state.workspace_identity <- Types.Workspace_identity_match;
  state.server_identity <- Some (workspace ());
  state.task_inspection_reader <-
    Some
      { Types.tci_original = owner
      ; tci_authority = state.workspace_authority
      ; tci_reading = state.workspace_read_authority
      ; tci_surface = state.view
      ; tci_target = state.msg_target_keeper_name };
  owner

let begin_task state =
  match Types.begin_original_task_inspection state with
  | Some request -> request
  | None -> Alcotest.fail "the Task read did not start"

let begin_history state =
  match Types.begin_original_history_inspection state ~earlier:false ~limit:1 with
  | Some request -> request
  | None -> Alcotest.fail "the history read did not start"

let failure = function
  | Fetched.Failed error -> Some error
  | Fetched.Absent | Fetched.Loading | Fetched.Ready _ | Fetched.Stale _ -> None

let awaited owner = Types.task_inspection_pending owner
let shown owner = Types.task_inspection_source owner

(* [name] matches every constructor, so a new answer does not compile until it
   is named here. [answers] is written by hand: a new answer goes there too. *)
let name : Original.msg -> string = function
  | Original.Original_task_read_done _ -> "Task read"
  | Original.Original_task_history_done _ -> "history read"
  | Original.Original_task_evidence_done _ -> "evidence read"

let answers () =
  let state = fresh () in
  let _owner = open_inspection state in
  let request = begin_task state in
  [ Original.Original_task_read_done (request, Error (Read.Read_failed "not read"))
  ; Original.Original_task_history_done (request, Error (Read.Read_failed "not read"))
  ; Original.Original_task_evidence_done (request, Error (Read.Read_failed "not read")) ]

let test_every_answer_is_a_read () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " is a read")
        true
        (Protocol.workspace_message_is_read (Protocol.Original_msg answer)))
    (answers ())

let test_no_answer_waits_for_input () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " does not wait for input")
        false
        (Protocol.message_waits_for_input
           ~resource_read:(fun _ -> true)
           ~recovery_loaded:(fun _ -> true)
           (Protocol.Original_msg answer)))
    (answers ())

let test_a_task_read_lands_while_its_inspector_is_current () =
  let state = fresh () in
  let owner = open_inspection state in
  let request = begin_task state in
  Original.apply state (Original.Original_task_read_done (request, Error (Read.Read_failed "boom")));
  Alcotest.(check bool) "the read is no longer awaited" true (Option.is_none (awaited owner));
  Alcotest.(check bool) "the Task shows the read's own failure" true
    (failure (Read.task_observation (shown owner)) = Some (Read.Read_failed "boom"))

let test_a_history_read_lands_while_its_inspector_is_current () =
  let state = fresh () in
  let owner = open_inspection state in
  let request = begin_history state in
  Original.apply state
    (Original.Original_task_history_done (request, Error (Read.Read_failed "boom")));
  Alcotest.(check bool) "the read is no longer awaited" true (Option.is_none (awaited owner));
  Alcotest.(check bool) "the history shows the read's own failure" true
    (failure (Read.history_observation (shown owner)) = Some (Read.Read_failed "boom"))

let test_an_answer_after_the_inspector_left_suspends_the_inspection () =
  let state = fresh () in
  let owner = open_inspection state in
  let request = begin_task state in
  state.view <- Types.Board;
  Original.apply state (Original.Original_task_read_done (request, Error (Read.Read_failed "boom")));
  Alcotest.(check bool) "the read is no longer awaited" true (Option.is_none (awaited owner));
  Alcotest.(check bool) "the Task is suspended instead of showing the answer" true
    (match failure (Read.task_observation (shown owner)) with
     | Some (Read.Workspace_unconfirmed _) -> true
     | Some (Read.Read_failed _ | Read.Invalid_reply _ | Read.Interrupted) | None -> false)

let test_an_answer_no_longer_awaited_changes_nothing () =
  let state = fresh () in
  let owner = open_inspection state in
  let task = begin_task state in
  let history = begin_history state in
  Original.apply state (Original.Original_task_read_done (task, Error (Read.Read_failed "late")));
  Alcotest.(check bool) "the history read is still awaited" true
    (match awaited owner with Some pending -> pending == history | None -> false);
  Alcotest.(check bool) "the late Task answer did not land" true
    (failure (Read.task_observation (shown owner)) <> Some (Read.Read_failed "late"))

let () =
  Alcotest.run "tui original msg"
    [ ( "classifiers"
      , [ Alcotest.test_case "every Original answer is a read" `Quick test_every_answer_is_a_read
        ; Alcotest.test_case "no Original answer waits for input" `Quick
            test_no_answer_waits_for_input ] )
    ; ( "apply"
      , [ Alcotest.test_case "a Task read lands while its inspector is current" `Quick
            test_a_task_read_lands_while_its_inspector_is_current
        ; Alcotest.test_case "a history read lands while its inspector is current" `Quick
            test_a_history_read_lands_while_its_inspector_is_current
        ; Alcotest.test_case "an answer after the inspector left suspends the inspection" `Quick
            test_an_answer_after_the_inspector_left_suspends_the_inspection
        ; Alcotest.test_case "an answer no longer awaited changes nothing" `Quick
            test_an_answer_no_longer_awaited_changes_nothing ] ) ]
