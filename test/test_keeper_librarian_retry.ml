open Alcotest

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Context = Masc.Keeper_librarian_context

let () =
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let librarian_subject_keeper = "retry-test-keeper"

let input ?(working_context = Context.empty) ?(goal_context = Librarian.No_task)
      ?(keeper_instructions = "You are the retry-test keeper.") () : Librarian.input =
  { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-retry" ~absolute_turn:1
  ; goal_context
  ; keeper_id = Masc_test_deps.keeper_id_fixture librarian_subject_keeper
  ; keeper_instructions
  ; working_context
  }
;;

type template_piece =
  | Template_text of string
  | Template_slot of string

let template_pieces template =
  let len = String.length template in
  let rec loop pos acc =
    if pos >= len
    then List.rev acc
    else (
      match String_util.find_substring ~pos template "{{" with
      | None -> List.rev (Template_text (String.sub template pos (len - pos)) :: acc)
      | Some open_at ->
        let acc =
          if open_at > pos
          then Template_text (String.sub template pos (open_at - pos)) :: acc
          else acc
        in
        let name_start = open_at + 2 in
        (match String_util.find_substring ~pos:name_start template "}}" with
         | None -> List.rev (Template_text (String.sub template open_at (len - open_at)) :: acc)
         | Some close_at ->
           let name = String.sub template name_start (close_at - name_start) |> String.trim in
           loop (close_at + 2) (Template_slot name :: acc)))
  in
  loop 0 []
;;

let template_slot_names template =
  template_pieces template
  |> List.filter_map (function Template_slot name -> Some name | Template_text _ -> None)
  |> List.sort_uniq String.compare
;;

let user_text_of_messages = function
  | [ (msg : Llm_provider.Types.message) ] -> Llm_provider.Types.text_of_content msg.content
  | messages -> failf "expected 1 message, got %d" (List.length messages)
;;

let occurrences ~needle text =
  let step = String.length needle in
  let rec count from acc =
    match String_util.find_substring ~pos:from text needle with
    | None -> acc
    | Some at -> count (at + step) (acc + 1)
  in
  count 0 0
;;

let test_working_contexts_strict_json_boundary () =
  let inp = input () in
  (match Librarian.working_contexts_of_json_result inp (`Assoc [ "working_contexts", `List [] ]) with
   | Ok [] -> ()
   | Ok _ -> fail "empty working_contexts must return []"
   | Error err -> fail (Librarian.parse_error_to_string err));
  (match Librarian.working_contexts_of_json_result inp (`List []) with
   | Error Librarian.Top_level_not_object -> ()
   | _ -> fail "non-object must return Top_level_not_object");
  (match Librarian.working_contexts_of_json_result inp (`Assoc []) with
   | Error Librarian.Missing_required_fields -> ()
   | _ -> fail "missing working_contexts must be rejected");
  (match
     Librarian.working_contexts_of_json_result inp
       (`Assoc [ "working_contexts", `List []; "new_claims", `List [] ])
   with
   | Error (Librarian.Unexpected_field "new_claims") -> ()
   | _ -> fail "unexpected Memory field must be rejected");
  match
    Librarian.working_contexts_of_json_result inp
      (`Assoc [ "working_contexts", `List []; "working_contexts", `List [] ])
  with
  | Error (Librarian.Duplicate_field "working_contexts") -> ()
  | _ -> fail "duplicate field must be rejected"
;;

let test_working_context_accepts_source_backed_pocket () =
  let source : Context.source =
    { reference = "chat:op-1"; content = `Assoc [ "message", `String "Review the draft" ] }
  in
  let inp = input ~working_context:{ Context.empty with sources = [ source ] } () in
  let payload =
    `Assoc
      [ ( "working_contexts"
        , `List
            [ `Assoc
                [ "merge_contexts", `List []
                ; "sources", `List [ `String "s1" ]
                ; "context", `String "Draft review requested"
                ; "next_steps", `List [ `String "Read the draft" ]
                ]
            ] )
      ]
  in
  match Librarian.working_contexts_of_json_result inp payload with
  | Ok [ pocket ] ->
    check (list string) "pocket cites the selected source" [ "chat:op-1" ] pocket.sources;
    check string "pocket summary preserved" "Draft review requested" pocket.context
  | Ok pockets -> failf "expected 1 pocket, got %d" (List.length pockets)
  | Error err -> fail (Librarian.parse_error_to_string err)
;;

let test_working_context_prompt_carries_no_current_memory () =
  let inp = input () in
  let vars = Librarian.working_context_prompt_variables inp in
  check bool "working-context pass supplies no current_memory variable" false
    (List.mem_assoc "current_memory" vars);
  check bool "working-context template has no current_memory slot" false
    (List.mem "current_memory"
       (template_slot_names (Prompt_registry.get_prompt Prompt_names.librarian_working_context)))
;;

let test_working_context_prompt_names_keeper_and_instructions () =
  (match Runtime.working_context_messages (input ()) with
   | Error detail -> failf "render failed: %s" detail
   | Ok messages ->
     let text = user_text_of_messages messages in
     check int "carries Keeper id once" 1 (occurrences ~needle:librarian_subject_keeper text);
     check bool "carries Keeper id on its own line" true
       (List.exists
          (fun line -> String.equal (String.trim line) librarian_subject_keeper)
          (String.split_on_char '\n' text));
     check bool "carries Keeper instructions" true
       (String_util.contains_substring text "You are the retry-test keeper."));
  match Runtime.working_context_messages (input ~keeper_instructions:"" ()) with
  | Error detail -> failf "blank instructions render failed: %s" detail
  | Ok messages ->
    check bool "blank Keeper instructions render explicit marker" true
      (String_util.contains_substring (user_text_of_messages messages) "[no keeper instructions]")
;;

let test_working_context_prompt_carries_goal_criteria () =
  let criterion =
    Goal_store.Criterion
      { revision = "criterion-audio-1"
      ; title = "Publish a playable audio essay"
      ; measure = Goal_measure_fixture.done_when "1"
      ; procedure = "independently reviewed audio essays"
      }
  in
  let render goal_context =
    match Runtime.working_context_messages (input ~goal_context ()) with
    | Error detail -> failf "Goal context render failed: %s" detail
    | Ok messages -> user_text_of_messages messages
  in
  let rendered =
    render
      (Librarian.Task_goals
         { task_id = "task-audio"; criteria = Ok [ "goal-audio", Goal_phase.Executing, criterion ] })
  in
  List.iter
    (fun text ->
       check bool ("model receives " ^ text) true (String_util.contains_substring rendered text))
    [ "task-audio"; "goal-audio"; "criterion-audio-1"; "independently reviewed audio essays" ];
  let unavailable =
    render (Librarian.Task_goals { task_id = "task-audio"; criteria = Error "Goal source unreadable" })
  in
  check bool "read failure is visible" true
    (String_util.contains_substring unavailable "Goal source unreadable");
  check bool "no task remains explicit" true
    (String_util.contains_substring (render Librarian.No_task) "no_task")
;;

let () =
  run
    "keeper_librarian_working_context"
    [ ( "working_context"
      , [ test_case "strict JSON boundary" `Quick test_working_contexts_strict_json_boundary
        ; test_case "source-backed pocket validates" `Quick
            test_working_context_accepts_source_backed_pocket
        ; test_case "working-context prompt carries no current memory" `Quick
            test_working_context_prompt_carries_no_current_memory
        ; test_case "working-context prompt names Keeper and instructions" `Quick
            test_working_context_prompt_names_keeper_and_instructions
        ; test_case "working-context prompt carries goal criteria" `Quick
            test_working_context_prompt_carries_goal_criteria
        ] )
    ]
;;
