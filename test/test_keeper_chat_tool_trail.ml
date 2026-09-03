(* Keeper_chat_tool_trail turns the tool events a connector adapter deliberately
   does not project into one block it can carry on the reply. These cases pin
   what a reader gets from that block. *)

module Trail = Masc.Keeper_chat_tool_trail
module Events = Masc.Keeper_chat_events

let subject ~name ~args = Trail.tool_subject ~name ~args

let check_subject description ~args expected =
  Alcotest.(check (option string)) description expected (subject ~name:"Tool" ~args)
;;

(* --- subject ------------------------------------------------------------- *)

let test_subject_argv () =
  check_subject
    "argv renders as the command that ran"
    ~args:{|{"argv":["git","fetch","origin"],"cwd":"repos/masc","timeout_sec":120}|}
    (Some "git fetch origin")
;;

(* Execute takes argv or a shell line, and 376 of the fleet's Execute calls in
   one day carried the line. Without [script] in the subject keys the row fell
   through to the whole-object rendering, and the path inside the line then met
   the path-tail shortener: a keeper's command read as a JSON fragment ending
   in a directory name. *)
let test_subject_script () =
  check_subject
    "a shell line renders as the line that ran"
    ~args:{|{"script":"rg -n prompt_fingerprint lib/ | head -20","cwd":".","timeout_sec":60}|}
    (Some "rg -n prompt_fingerprint lib/ | head -20")
;;

(* argv keeps its place: a call that carries both is not one the schema
   accepts, and the direct form is the one that names a program. *)
let test_subject_argv_wins_over_script () =
  check_subject
    "argv is read before script"
    ~args:{|{"argv":["git","status"],"script":"git status"}|}
    (Some "git status")
;;

let test_subject_file_path () =
  check_subject
    "a file call is named by its path"
    ~args:{|{"file_path":"repos/masc/lib/tool_agent.ml","limit":40}|}
    (Some "repos/masc/lib/tool_agent.ml")
;;

let test_subject_pattern_before_path () =
  check_subject
    "a search is named by what it looked for, not where"
    ~args:{|{"glob":"*.ml","path":"repos/masc/lib","pattern":"agent block"}|}
    (Some "agent block")
;;

(* The known keys are a preference, not a gate. A shape none of them matches is
   still named by its arguments, because the alternative is a bare tool name:
   on one live keeper three of six calls had no matching key
   ([keeper_tasks_audit {"limit":20}], [masc_agent_timeline
   {"agent_name":…,"limit":5,…}], [masc_agent_card {}]) and scrolled back
   saying only that some tool ran. *)
(* [keeper_skill] carries its identity one level down, and the whole-object
   fallback below could not reach it: the envelope
   [{"identity":{"source_id":"…","package_id":"…"] spends the 72-cell budget
   before the [name] value begins, so two skills published from one source
   scrolled back as the same row.

   The name is what a reader of the conversation is after -- which skill ran
   -- so the descent names it. *)
let test_subject_reaches_a_nested_identity () =
  check_subject
    "a skill call names the skill, not its envelope"
    ~args:
      {|{"identity":{"source_id":"project-masc","package_id":"masc-keeper-autonomy","name":"turn-opening"},"content_revision":"a1b2c3"}|}
    (Some "turn-opening")
;;

(* Two skills from one source used to render alike: the shared prefix is what
   the budget spent itself on. This is the pair that made it visible. *)
let test_two_skills_from_one_source_read_apart () =
  let subject_of args =
    subject ~name:"keeper_skill" ~args
  in
  let first =
    subject_of
      {|{"identity":{"source_id":"project-masc","package_id":"masc-keeper-autonomy","name":"turn-opening"}}|}
  in
  let second =
    subject_of
      {|{"identity":{"source_id":"project-masc","package_id":"masc-keeper-autonomy","name":"work-intake"}}|}
  in
  Alcotest.(check bool)
    "the two calls do not read the same" false
    (Option.equal String.equal first second)
;;

(* The descent does not outrank a key the object carries itself. A tool that
   names its own subject keeps naming it. *)
let test_a_direct_key_still_wins () =
  check_subject
    "the object's own key comes first"
    ~args:{|{"file_path":"lib/a.ml","identity":{"name":"turn-opening"}}|}
    (Some "lib/a.ml")
;;

let test_subject_absent_keys () =
  check_subject
    "an argument shape with no known key is named by its arguments"
    ~args:{|{"include_done":true,"if_revision":12}|}
    (Some {|{"include_done":true,"if_revision":12}|})
;;

(* The empty object is the one shape that legitimately names nothing: there is
   no argument to show. *)
let test_subject_empty_object () =
  check_subject "an empty argument object names nothing" ~args:"{}" None
;;

(* The six tool calls one live keeper had actually made, as the transcript
   stored them. Three of them named nothing before the fallback, which is what
   sent an operator looking for the tool trail that was already there. *)
let test_subject_names_the_live_masc_shapes () =
  check_subject "an agent timeline is named by whose it is"
    ~args:
      {|{"agent_name":"keeper-bandleader-agent","limit":5,"include_tasks":true}|}
    (Some "keeper-bandleader-agent");
  check_subject "an audit with only a limit still says its limit"
    ~args:{|{"limit":20}|}
    (Some {|{"limit":20}|});
  check_subject "a card with no arguments names nothing" ~args:"{}" None;
  check_subject "an Execute is named by the command it ran"
    ~args:{|{"argv":["git","-C","repos/masc","status","--short"]}|}
    (Some "git -C repos/masc status --short")
;;

let test_subject_empty_args () = check_subject "no arguments name nothing" ~args:"" None

let test_subject_empty_value () =
  check_subject "an empty value is not a name" ~args:{|{"file_path":"   "}|} None
;;

let test_subject_partial_json () =
  (* Arguments stream in as fragments; a fragment still names the call better
     than nothing does. *)
  check_subject
    "an unparsable fragment falls back to its own text"
    ~args:{|{"file_path":"lib/keep|}
    (Some {|{"file_path":"lib/keep|})
;;

let test_subject_keeps_path_tail () =
  let long = "repos/masc/" ^ String.concat "" (List.init 20 (fun _ -> "nested/")) ^ "target.ml" in
  match subject ~name:"Read" ~args:(Printf.sprintf {|{"file_path":%S}|} long) with
  | None -> Alcotest.fail "a long path should still name the call"
  | Some rendered ->
    Alcotest.(check bool) "keeps the file name" true (Filename.basename rendered = "target.ml");
    Alcotest.(check bool) "marks the cut" true (String.length rendered > 0 && rendered.[0] = '\xe2');
    Alcotest.(check bool) "stays within the row budget" true (String.length rendered <= 72)
;;

(* --- accumulation and rendering ------------------------------------------ *)

let trail_of events =
  let t = Trail.create () in
  List.iter (Trail.on_event t) events;
  t
;;

let occurrence id =
  { Events.stream_scope = 0; provider_message_id = None; block_index = Hashtbl.hash id }
;;

let tool_start id name =
  Events.Tool_call_start
    { occurrence = occurrence id
    ; tool_call_id = Some id
    ; tool_call_name = name
    }
;;

let tool_args id delta =
  Events.Tool_call_args
    { occurrence = occurrence id; tool_call_id = Some id; delta }
;;

let tool_snapshot id snapshot =
  Events.Tool_call_args_snapshot
    { occurrence = occurrence id; tool_call_id = Some id; snapshot }
;;

let test_no_tools_renders_nothing () =
  let t = trail_of [ Events.Text_delta "answered from memory" ] in
  Alcotest.(check int) "no calls" 0 (Trail.call_count t);
  Alcotest.(check (option string)) "no block" None (Trail.render t)
;;

let test_argument_deltas_accumulate () =
  let t =
    trail_of
      [ tool_start "c1" "Read"
      ; tool_args "c1" {|{"file_pa|}
      ; tool_args "c1" {|th":"lib/a.ml"}|}
      ]
  in
  Alcotest.(check (option string))
    "deltas join into one argument object"
    (Some "└ Read lib/a.ml")
    (Trail.render t)
;;

let test_snapshot_replaces_deltas () =
  (* The provider sends a snapshot instead of its deltas, not in addition. *)
  let t =
    trail_of
      [ tool_start "c1" "Read"; tool_args "c1" {|{"file_path":"wr|}
      ; tool_snapshot "c1" {|{"file_path":"lib/right.ml"}|}
      ]
  in
  Alcotest.(check (option string))
    "the snapshot wins"
    (Some "└ Read lib/right.ml")
    (Trail.render t)
;;

let test_fragment_for_unknown_id_is_dropped () =
  let t = trail_of [ tool_args "never-opened" {|{"file_path":"lib/a.ml"}|} ] in
  Alcotest.(check int) "no call opened" 0 (Trail.call_count t);
  Alcotest.(check (option string)) "nothing to render" None (Trail.render t)
;;

let test_repeated_start_is_one_call () =
  let t = trail_of [ tool_start "c1" "Read"; tool_start "c1" "Read" ] in
  Alcotest.(check int) "same id is the same call" 1 (Trail.call_count t)
;;

let test_rows_keep_call_order_and_branch () =
  let t =
    trail_of
      [ tool_start "c1" "Read"
      ; tool_snapshot "c1" {|{"file_path":"lib/a.ml"}|}
      ; tool_start "c2" "Execute"
      ; tool_snapshot "c2" {|{"argv":["git","status"]}|}
      ]
  in
  Alcotest.(check (option string))
    "rows follow the order the calls opened, last one closing the branch"
    (Some "├ Read    lib/a.ml\n└ Execute git status")
    (Trail.render t)
;;

let test_rows_past_the_cap_become_a_count () =
  let events =
    List.concat_map
      (fun i ->
        let id = Printf.sprintf "c%d" i in
        [ tool_start id "Read"; tool_snapshot id (Printf.sprintf {|{"file_path":"lib/%d.ml"}|} i) ])
      (List.init 5 Fun.id)
  in
  match Trail.render ~max_rows:2 (trail_of events) with
  | None -> Alcotest.fail "five calls should render"
  | Some rendered ->
    let lines = String.split_on_char '\n' rendered in
    Alcotest.(check int) "two rows and the count" 3 (List.length lines);
    Alcotest.(check string) "the count names what it left out" "└ 그 외 3개" (List.nth lines 2)
;;

let test_call_without_arguments_still_gets_a_row () =
  let t = trail_of [ tool_start "c1" "keeper_context_status" ] in
  Alcotest.(check (option string))
    "a call with no arguments is still work the reader should see"
    (Some "└ keeper_context_status")
    (Trail.render t)
;;

(* --- append_to ------------------------------------------------------------ *)

let test_append_to_fences_the_block () =
  let t = trail_of [ tool_start "c1" "Read"; tool_snapshot "c1" {|{"file_path":"lib/a.ml"}|} ] in
  Alcotest.(check string)
    "the reply keeps its text and gains a fenced trail"
    "answer\n```\n└ Read lib/a.ml\n```"
    (Trail.append_to t ~text:"answer")
;;

let test_append_to_leaves_a_toolless_reply_alone () =
  let t = trail_of [] in
  Alcotest.(check string) "unchanged" "answer" (Trail.append_to t ~text:"answer")
;;

let test_append_to_leaves_an_empty_reply_empty () =
  (* A turn with no text keeps whatever no-text outcome its adapter has; a bare
     trail is not an answer. *)
  let t = trail_of [ tool_start "c1" "Read"; tool_snapshot "c1" {|{"file_path":"lib/a.ml"}|} ] in
  Alcotest.(check string) "unchanged" "" (Trail.append_to t ~text:"")
;;

(* --- result digest ------------------------------------------------------- *)

let check_digest description ~result expected =
  Alcotest.(check (option string))
    description
    expected
    (Trail.tool_result_digest ~result)
;;

(* The envelopes measured on one keeper's newest hundred calls. Written out
   rather than reduced to one case: the point is that a row says something
   useful for each shape this workspace actually writes. *)
let test_digest_reads_the_live_envelopes () =
  check_digest
    "a command answers with its output, not its envelope"
    ~result:{|{"ok":true,"cwd":".","execution_time_ms":529,"output":"65de95f856 chore(glm)"}|}
    (Some "65de95f856 chore(glm)");
  check_digest
    "a failure says why before anything else"
    ~result:{|{"ok":false,"cwd":".","error":"exit 128: not a git repository","output":"

"}|}
    (Some "exit 128: not a git repository");
  check_digest
    "a read answers with what it read"
    ~result:{|{"ok":true,"path":"lib/a.ml","bytes":12,"content":"let x = 1"}|}
    (Some "let x = 1");
  check_digest
    "a write with no text payload names the file it wrote"
    ~result:{|{"ok":true,"mode":"create","bytes_written":40,"path":"repos/masc/a.ml"}|}
    (Some "repos/masc/a.ml")
;;

(* Seventeen of that hundred were not JSON at all. The text is the result. *)
let test_digest_takes_plain_text_as_it_is () =
  check_digest "plain text needs shortening, not parsing"
    ~result:"  backlog is empty  " (Some "backlog is empty")
;;

(* A shape with none of the known keys is still better named by its own text
   than by nothing -- the same fallback the subject takes. *)
let test_digest_falls_back_to_the_whole_shape () =
  check_digest "an unknown shape names itself"
    ~result:{|{"ok":true,"occurrences":3}|}
    (Some {|{"ok":true,"occurrences":3}|})
;;

(* An empty result is a call that answered nothing. A row can leave that
   blank; padding it with "" would say the call answered an empty string. *)
let test_digest_of_an_empty_result_is_absent () =
  check_digest "empty" ~result:"" None;
  check_digest "whitespace only" ~result:"   \n  " None
;;

(* Long results are cut to the same width a subject is, so one row cannot
   push the ones under it off the screen. *)
let test_digest_is_bounded () =
  match Trail.tool_result_digest ~result:(String.make 4000 'x') with
  | None -> Alcotest.fail "a long result should still name itself"
  | Some digest ->
      Alcotest.(check bool)
        (Printf.sprintf "a 4000-byte result is cut (got %d bytes)"
           (String.length digest))
        true
        (String.length digest < 200)
;;

let () =
  Alcotest.run
    "keeper_chat_tool_trail"
    [ ( "subject"
      , [ Alcotest.test_case "argv" `Quick test_subject_argv
        ; Alcotest.test_case "script" `Quick test_subject_script
        ; Alcotest.test_case "argv before script" `Quick test_subject_argv_wins_over_script
        ; Alcotest.test_case "file_path" `Quick test_subject_file_path
        ; Alcotest.test_case "pattern before path" `Quick test_subject_pattern_before_path
        ; Alcotest.test_case "unknown keys" `Quick test_subject_absent_keys
        ; Alcotest.test_case "a nested identity is reached" `Quick
            test_subject_reaches_a_nested_identity
        ; Alcotest.test_case "two skills from one source read apart" `Quick
            test_two_skills_from_one_source_read_apart
        ; Alcotest.test_case "a direct key still wins" `Quick
            test_a_direct_key_still_wins
        ; Alcotest.test_case "empty object" `Quick test_subject_empty_object
        ; Alcotest.test_case "live masc shapes" `Quick
            test_subject_names_the_live_masc_shapes
        ; Alcotest.test_case "empty args" `Quick test_subject_empty_args
        ; Alcotest.test_case "empty value" `Quick test_subject_empty_value
        ; Alcotest.test_case "partial json" `Quick test_subject_partial_json
        ; Alcotest.test_case "long path keeps its tail" `Quick test_subject_keeps_path_tail
        ] )
    ; ( "result digest"
      , [ Alcotest.test_case "live envelopes" `Quick
            test_digest_reads_the_live_envelopes
        ; Alcotest.test_case "plain text" `Quick
            test_digest_takes_plain_text_as_it_is
        ; Alcotest.test_case "unknown shape" `Quick
            test_digest_falls_back_to_the_whole_shape
        ; Alcotest.test_case "empty result" `Quick
            test_digest_of_an_empty_result_is_absent
        ; Alcotest.test_case "bounded" `Quick test_digest_is_bounded
        ] )
    ; ( "trail"
      , [ Alcotest.test_case "no tools" `Quick test_no_tools_renders_nothing
        ; Alcotest.test_case "deltas accumulate" `Quick test_argument_deltas_accumulate
        ; Alcotest.test_case "snapshot replaces" `Quick test_snapshot_replaces_deltas
        ; Alcotest.test_case "unknown id dropped" `Quick test_fragment_for_unknown_id_is_dropped
        ; Alcotest.test_case "repeated start" `Quick test_repeated_start_is_one_call
        ; Alcotest.test_case "order and branch" `Quick test_rows_keep_call_order_and_branch
        ; Alcotest.test_case "cap becomes a count" `Quick test_rows_past_the_cap_become_a_count
        ; Alcotest.test_case "no arguments" `Quick test_call_without_arguments_still_gets_a_row
        ] )
    ; ( "append_to"
      , [ Alcotest.test_case "fences the block" `Quick test_append_to_fences_the_block
        ; Alcotest.test_case "no tools" `Quick test_append_to_leaves_a_toolless_reply_alone
        ; Alcotest.test_case "empty reply" `Quick test_append_to_leaves_an_empty_reply_empty
        ] )
    ]
;;
