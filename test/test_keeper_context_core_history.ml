(** Tests for {!Masc.Keeper_context_core_history} (RFC librarian-lifecycle
    §10-3): every history line names the turn that wrote it, a tool call an
    official-client turn made leaves an observation line, appends are locked
    and durable, and a line the store refuses does not stop the turn. *)

open Alcotest

module History = Masc.Keeper_context_core_history
module Types = Agent_core.Types

let keeper_name = "keeper"
let trace_id = "trace"
let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:7

let message ~role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

let with_session f =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "keeper-history-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
       let session = Masc.Keeper_context_core.create_session ~session_id:trace_id ~base_dir in
       f session)
;;

let lines_of path =
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")
;;

let fields_of line =
  match Yojson.Safe.from_string line with
  | `Assoc fields -> fields
  | _ -> failf "history line is not an object: %s" line
;;

let turn_ref_of fields =
  match List.assoc_opt History.key_turn_ref fields with
  | Some json ->
    (match Ids.Turn_ref.of_yojson json with
     | Ok turn_ref -> turn_ref
     | Error error -> failf "turn_ref does not decode: %s" error)
  | None -> fail "history line carries no turn_ref"
;;

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> value
  | Some json -> failf "%s is not a string: %s" key (Yojson.Safe.to_string json)
  | None -> failf "history line carries no %s" key
;;

(* The user line and the assistant line of one turn say which turn, so a
   reader can take them together without a clock. *)
let test_a_turns_lines_carry_its_turn_ref () =
  with_session
  @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref ~source:"user" session
    (message ~role:Types.User "question");
  History.persist_message ~keeper_name ~turn_ref ~source:"assistant" session
    (message ~role:Types.Assistant "answer");
  match lines_of (History.main_history_path ~session_dir:session.session_dir) with
  | [ user; assistant ] ->
    List.iter
      (fun line ->
         let fields = fields_of line in
         check bool "the line names the turn" true
           (Ids.Turn_ref.equal turn_ref (turn_ref_of fields));
         check string "the line is a message" History.kind_message
           (string_field History.key_kind fields);
         (match List.assoc_opt History.key_ts_unix fields with
          | Some (`Float ts) -> check bool "ts_unix is an epoch" true (ts > 0.0)
          | _ -> fail "ts_unix is not a float"))
      [ user; assistant ];
    check string "the first line is the user's" "user" (string_field "role" (fields_of user));
    check string "the second line is the assistant's" "assistant"
      (string_field "role" (fields_of assistant))
  | lines -> failf "expected two history lines, read %d" (List.length lines)
;;

(* A tool call leaves its name and outcome, nothing of its arguments or
   result, in the internal file. *)
let test_a_tool_observation_names_the_call () =
  with_session
  @@ fun session ->
  History.persist_tool_observation ~keeper_name ~turn_ref session
    ~tool_name:"masc_tasks" ~outcome:Tool_result.Error;
  check bool "the main file stays untouched" false
    (Sys.file_exists (History.main_history_path ~session_dir:session.session_dir));
  match lines_of (History.internal_history_path ~session_dir:session.session_dir) with
  | [ line ] ->
    let fields = fields_of line in
    check bool "the line names the turn" true
      (Ids.Turn_ref.equal turn_ref (turn_ref_of fields));
    check string "the line is an observation" History.kind_tool_observation
      (string_field History.key_kind fields);
    check string "the tool" "masc_tasks" (string_field History.key_tool_name fields);
    check string "the outcome" "error" (string_field History.key_outcome fields);
    check int "nothing else" 5 (List.length fields)
  | lines -> failf "expected one observation line, read %d" (List.length lines)
;;

(* An append that died mid-line leaves a torn tail; the next append cuts it
   under the lock, so a reader never meets a torn middle. *)
let test_a_torn_tail_is_cut_by_the_next_append () =
  with_session
  @@ fun session ->
  let path = History.main_history_path ~session_dir:session.session_dir in
  Fs_compat.mkdir_p session.session_dir;
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc {|{"kind":"mess|});
  History.persist_message ~keeper_name ~turn_ref session (message ~role:Types.User "after");
  match lines_of path with
  | [ line ] ->
    let fields = fields_of line in
    check string "the surviving line is the appended one" "after"
      (match List.assoc_opt "content_blocks" fields with
       | Some (`List [ `Assoc block ]) -> string_field "text" block
       | _ -> "<no text>");
    check bool "the torn tail is gone" false
      (String.starts_with ~prefix:{|{"kind":"mess|}
         (In_channel.with_open_bin path In_channel.input_all))
  | lines -> failf "expected one line after the cut, read %d" (List.length lines)
;;

let fragment_failures ~site =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string HistoryFragmentFailures)
    ~labels:[ "keeper", keeper_name; "site", site ]
    ()
;;

(* Constructing the failure handler must not report a failure. Exercise both
   production writers and check their durable lines as well as telemetry. *)
let test_successful_fragments_do_not_report_failures () =
  with_session @@ fun session ->
  let before_append = fragment_failures ~site:"append" in
  let before_encode = fragment_failures ~site:"encode" in
  History.persist_message ~keeper_name ~turn_ref session (message ~role:Types.User "saved");
  check (float 0.) "successful message has no append failure" before_append
    (fragment_failures ~site:"append");
  History.persist_tool_observation ~keeper_name ~turn_ref session
    ~tool_name:"masc_tasks" ~outcome:Tool_result.Ok;
  check (float 0.) "successful observation has no append failure" before_append
    (fragment_failures ~site:"append");
  check (float 0.) "successful fragments have no encoding failure" before_encode
    (fragment_failures ~site:"encode");
  check int "message was actually saved" 1
    (List.length (lines_of (History.main_history_path ~session_dir:session.session_dir)));
  check int "observation was actually saved" 1
    (List.length (lines_of (History.internal_history_path ~session_dir:session.session_dir)))
;;

(* A store the writer cannot append to: the path is a directory. The refusal
   is counted, nothing is raised, and the turn that called goes on. *)
let test_a_refused_line_does_not_raise () =
  with_session
  @@ fun session ->
  let path = History.main_history_path ~session_dir:session.session_dir in
  Fs_compat.mkdir_p path;
  let before = fragment_failures ~site:"append" in
  History.persist_message ~keeper_name ~turn_ref session (message ~role:Types.User "lost");
  check (float 0.0001) "the refusal is counted" (before +. 1.0)
    (fragment_failures ~site:"append");
  check bool "the store is as it was" true
    (Sys.is_directory path && Array.length (Sys.readdir path) = 0)
;;

let () =
  run
    "keeper_context_core_history"
    [ ( "lines"
      , [ test_case "a turn's lines carry its turn_ref" `Quick
            test_a_turns_lines_carry_its_turn_ref
        ; test_case "a tool observation names the call" `Quick
            test_a_tool_observation_names_the_call
        ] )
    ; ( "durability"
      , [ test_case "successful fragments do not report failures" `Quick
            test_successful_fragments_do_not_report_failures
        ; test_case "a torn tail is cut by the next append" `Quick
            test_a_torn_tail_is_cut_by_the_next_append
        ; test_case "a refused line does not raise" `Quick
            test_a_refused_line_does_not_raise
        ] )
    ]
;;
