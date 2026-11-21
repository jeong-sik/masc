(** Tests for {!Masc.Keeper_turn_fragments} and the official-client rows of
    {!Masc.Keeper_librarian_range} (RFC librarian-lifecycle §10-3): what an
    official-client turn left in its trace's history files is read back by
    the turn's [turn_ref]; a line the decoder refuses is a typed stop and not
    an untagged line; and the official-turn end lines of the boundary log are
    selected by their line number, beyond a cursor. *)

open Alcotest

module Fragments = Masc.Keeper_turn_fragments
module History = Masc.Keeper_context_core_history
module Wire = Masc.Keeper_memory_os_types
module Types = Agent_core.Types

let keeper_name = "keeper"
let trace_id = "trace"
let turn n = Ids.Turn_ref.make ~trace_id ~absolute_turn:n

let message ~role text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

let with_session f =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "turn-fragments-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
       let session = Masc.Keeper_context_core.create_session ~session_id:trace_id ~base_dir in
       f session)
;;

let read session file =
  match Fragments.read ~session_dir:session.Keeper_types.session_dir file with
  | Ok lines -> lines
  | Error detail -> fail detail
;;

let append_raw session file text =
  let path = Fragments.path ~session_dir:session.Keeper_types.session_dir file in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat ] 0o600 path (fun oc ->
    Out_channel.output_string oc text)
;;

let text_of (fragment : Fragments.fragment) =
  match fragment with
  | Fragments.Message { message; _ } -> Types.text_of_content message.content
  | Fragments.Tool_observation { observation; _ } -> "tool:" ^ observation.tool_name
;;

(* What the writer wrote, the reader hands back under the turn that wrote it. *)
let test_a_turns_fragments_come_back_by_its_turn_ref () =
  with_session
  @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_user session
    (message ~role:Types.User "q1");
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_assistant session
    (message ~role:Types.Assistant "a1");
  History.persist_message ~keeper_name ~turn_ref:(turn 2) ~source:Masc.Keeper_types_support.Direct_user session
    (message ~role:Types.User "q2");
  History.persist_tool_observation ~keeper_name ~turn_ref:(turn 1) session
    ~tool_name:"masc_tasks" ~outcome:Tool_result.Error;
  let main = read session Fragments.Main in
  let internal = read session Fragments.Internal in
  check (list string) "turn 1, main file then internal, in file order"
    [ "q1"; "a1"; "tool:masc_tasks" ]
    (List.map text_of (Fragments.of_turn (turn 1) (main @ internal)));
  check (list string) "turn 2 alone" [ "q2" ]
    (List.map text_of (Fragments.of_turn (turn 2) (main @ internal)));
  (match Fragments.of_turn (turn 1) internal with
   | [ Fragments.Tool_observation { observation = { outcome = Masc.Keeper_librarian.Failed; _ }; _ } ] -> ()
   | _ -> fail "the observation's outcome is not the one written")
;;

(* A line from before lines named their turn belongs to no turn; a refused
   line among those predates turn-named history and stops nothing. A refused
   line after the first named one stops. *)
let test_untagged_lines_belong_to_no_turn_and_refusals_count_from_the_first_named () =
  with_session
  @@ fun session ->
  append_raw session Fragments.Main
    {|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}
not json at all
|};
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_user session (message ~role:Types.User "new");
  let lines = read session Fragments.Main in
  (match lines with
   | [ (1, Ok Fragments.Untagged); (2, Error (Fragments.Not_json _)); (3, Ok (Fragments.Fragment _)) ] -> ()
   | _ -> failf "unexpected shape of %d lines" (List.length lines));
  check bool "a refusal before the first named line stops nothing" true
    (Option.is_none (Fragments.first_refused lines));
  append_raw session Fragments.Main "{\"turn_ref\":\"trace#9\",\"kind\":\"riddle\",\"ts_unix\":2.0}\n";
  let lines = read session Fragments.Main in
  (match Fragments.first_refused lines with
   | Some (4, Fragments.Malformed _) -> ()
   | Some (line, error) -> failf "refused at %d: %s" line (Fragments.read_error_to_string error)
   | None -> fail "a refused line after the first named one did not stop")
;;

(* A tagged line the decoder cannot name is refused, never untagged: a wrong
   kind, an outcome this build does not know, a key the writer never
   writes, and a message the message decoder rejects. *)
let test_a_tagged_line_that_cannot_be_named_is_refused () =
  with_session
  @@ fun session ->
  append_raw session Fragments.Internal
    (String.concat "\n"
       [ {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"tool_observation","tool_name":"t","outcome":"maybe"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"user","origin":"conversation","content_blocks":[],"extra":1}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"user","origin":"conversation"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"not a ref","kind":"message"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"oracle","origin":"conversation","content_blocks":[]}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"tool_observation","tool_name":"t","outcome":"ok"}|}
       ]
     ^ "\n");
  let lines = read session Fragments.Internal in
  let kinds =
    List.map
      (fun (_, read) ->
         match read with
         | Ok (Fragments.Fragment _) -> "fragment"
         | Ok Fragments.Untagged -> "untagged"
         | Error (Fragments.Malformed _) -> "malformed"
         | Error (Fragments.Message_rejected _) -> "message_rejected"
         | Error (Fragments.Not_json _) -> "not_json"
         | Error Fragments.Incomplete_line -> "incomplete")
      lines
  in
  check (list string) "each line is named for what is wrong with it"
    [ "malformed"; "malformed"; "malformed"; "malformed"; "message_rejected"; "fragment" ]
    kinds
;;

(* An append that died mid-line is not a line: it is neither a fragment nor
   a refusal. *)
let test_a_torn_tail_is_not_a_line () =
  with_session
  @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_user session (message ~role:Types.User "whole");
  append_raw session Fragments.Main {|{"ts_unix":2.0,"turn_ref":"trace#2","ki|};
  let lines = read session Fragments.Main in
  (match lines with
   | [ (1, Ok (Fragments.Fragment _)); (2, Error Fragments.Incomplete_line) ] -> ()
   | _ -> failf "unexpected shape of %d lines" (List.length lines));
  check bool "the torn tail stops nothing" true (Option.is_none (Fragments.first_refused lines))
;;

let test_recent_messages_skip_tools_without_losing_provenance () =
  with_session @@ fun session ->
  let request = { (message ~role:Types.User (String.make 900 'x' ^ " remaining PR"))
    with metadata = Masc.Keeper_input_speaker.metadata
      (Masc.Keeper_input_speaker.Person Masc.Keeper_input_speaker.Owner) } in
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_user session request;
  for _ = 1 to 30 do
    History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_assistant session
      (message ~role:Types.Tool "tool result that must not displace the request");
    History.persist_tool_observation ~keeper_name ~turn_ref:(turn 1) session
      ~tool_name:"Execute" ~outcome:Tool_result.Ok
  done;
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_assistant session
    (message ~role:Types.Assistant "PR remains; next read the changed consumer");
  let read file roles limit =
    match Fragments.read_recent_messages ~session_dir:session.Keeper_types.session_dir
      ~roles ~limit file with
    | Ok window -> window.Fragments.messages
    | Error detail -> fail detail in
  (match read Fragments.Main [Types.User; Types.Assistant] 2 with
   | [ first; second ] ->
     check string "full request" (Types.text_of_message request)
       (Types.text_of_message first.message);
     check bool "original speaker metadata" true (first.message.metadata = request.metadata);
     check bool "original turn" true (Ids.Turn_ref.equal first.turn_ref (turn 1));
     check (option string) "source" (Some "direct_user") first.source;
     check string "reply" "PR remains; next read the changed consumer"
       (Types.text_of_message second.message)
   | _ -> fail "conversation messages were lost");
  check int "tool-only file is not a reply" 0
    (List.length (read Fragments.Internal [Types.Assistant] 1));
  History.persist_message ~keeper_name ~turn_ref:(turn 2) ~source:Masc.Keeper_types_support.Internal_assistant session
    (message ~role:Types.Assistant "consumer checked; next publish verdict");
  check (list string) "latest autonomous conclusion" ["consumer checked; next publish verdict"]
    (List.map (fun (m : Fragments.observed_message) -> Types.text_of_message m.message)
       (read Fragments.Internal [Types.Assistant] 1))
;;

let test_recent_messages_distinguish_missing_and_corrupt () =
  with_session @@ fun session ->
  let read () = Fragments.read_recent_messages
      ~session_dir:session.Keeper_types.session_dir ~roles:[Types.Assistant] ~limit:1 Fragments.Main in
  check bool "missing history is absent" true (read () = Ok {Fragments.messages=[];prefix_omitted=false});
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_assistant session (message ~role:Types.Assistant "old reply");
  append_raw session Fragments.Main "{broken\n";
  match read () with
  | Error _ -> ()
  | Ok _ -> fail "corruption silently became an older reply"
;;

let test_recent_messages_reject_complete_json_without_newline () =
  with_session @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Direct_assistant session
    (message ~role:Types.Assistant "committed reply");
  let file = Fragments.path ~session_dir:session.Keeper_types.session_dir Fragments.Main in
  let committed = In_channel.with_open_bin file In_channel.input_all in
  Out_channel.with_open_bin file (fun out ->
    output_string out (String.sub committed 0 (String.length committed - 1)));
  match Fragments.read_recent_messages ~session_dir:session.Keeper_types.session_dir
      ~roles:[Types.Assistant] ~limit:1 Fragments.Main with
  | Error _ -> ()
  | Ok _ -> fail "uncommitted JSON was presented as a previous reply"
;;

let test_recent_messages_report_a_tool_only_window () =
  with_session @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:Masc.Keeper_types_support.Internal_assistant session
    (message ~role:Types.Assistant "older reply outside physical window");
  (* One retained tool row alone exceeds the physical observation window. *)
  History.persist_message ~keeper_name ~turn_ref:(turn 2) ~source:Masc.Keeper_types_support.Internal_assistant session
    (message ~role:Types.Tool (String.make (Masc.Keeper_status_options_defaults.max_tail_bytes + 1) 'x'));
  match Fragments.read_recent_messages ~session_dir:session.Keeper_types.session_dir
      ~roles:[Types.Assistant] ~limit:1 Fragments.Internal with
  | Ok {messages=[];prefix_omitted=true} -> ()
  | Error detail -> fail detail
  | Ok _ -> fail "a clipped no-match window became full-history absence"
;;

let () =
  run
    "keeper_turn_fragments"
    [ ( "fragments"
      , [ test_case "recent messages retain conversation and provenance" `Quick
            test_recent_messages_skip_tools_without_losing_provenance
        ; test_case "recent messages distinguish missing and corrupt" `Quick
            test_recent_messages_distinguish_missing_and_corrupt
        ; test_case "recent messages reject uncommitted valid JSON" `Quick
            test_recent_messages_reject_complete_json_without_newline
        ; test_case "tool-only tail reports prefix omission" `Quick
            test_recent_messages_report_a_tool_only_window
        ; test_case "a turn's fragments come back by its turn_ref" `Quick
            test_a_turns_fragments_come_back_by_its_turn_ref
        ; test_case "untagged lines belong to no turn; refusals count from the first named" `Quick
            test_untagged_lines_belong_to_no_turn_and_refusals_count_from_the_first_named
        ; test_case "a tagged line that cannot be named is refused" `Quick
            test_a_tagged_line_that_cannot_be_named_is_refused
        ; test_case "a torn tail is not a line" `Quick test_a_torn_tail_is_not_a_line
        ] )
    ]
;;
