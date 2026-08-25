(* test_keeper_thinking_observation.ml — Thinking 행 feature test.

   The typed reasoning-observation pipe
   ([Keeper_agent_run_thinking_trajectory.persist_response_content]) must
   record one metadata-only entry per reasoning block — kind, turn,
   block_index, char_count — and never the reasoning text itself. The
   privacy half is the CoT-privacy contract: the persisted trajectory
   bytes must not contain any hidden content, and a redacted block must
   not even leak its length. *)

open Alcotest
module Obs = Masc.Keeper_agent_run_thinking_trajectory
module T = Agent_core.Types

(* Every case gets its own root AND its own trace id: Trajectory keeps
   per-(keeper, trace) writer state cached in-process, so reusing a path
   after rm_rf would leave a cached writer pointed at the unlinked file
   and the re-created directory would stay empty on read-back. *)
let case_counter = ref 0

let with_temp_masc_root f =
  incr case_counter;
  let case = !case_counter in
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "thinking-obs-%d-%d" (Unix.getpid ()) case)
  in
  Unix.mkdir root 0o755;
  let rec rm_rf path =
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () -> f root)
;;

let keeper_name = "thinker"
let trace_id () = Printf.sprintf "trace-think-%d" !case_counter

let make_acc root =
  Trajectory.create_accumulator
    ~masc_root:root
    ~keeper_name
    ~trace_id:(trace_id ())
    ()
;;

let hidden_thinking = "secret chain of thought"
let hidden_details = "hidden reasoning detail text"
let hidden_redacted = "opaque-provider-signature-blob"

let sample_content =
  [ T.Text "visible answer"
  ; T.Thinking { content = hidden_thinking; signature = None }
  ; T.ReasoningDetails
      { reasoning_content = Some hidden_details; details = [] }
  ; T.RedactedThinking hidden_redacted
  ; T.ReasoningDetails { reasoning_content = Some "   "; details = [] }
  ]
;;

let thinking_lines root =
  Trajectory.read_all_lines ~masc_root:root ~keeper_name ~trace_id:(trace_id ())
  |> List.filter_map (function
    | Trajectory.Withheld_thinking entry -> Some entry
    | Trajectory.Tool_call _ -> None)
;;

let test_records_one_entry_per_reasoning_block () =
  with_temp_masc_root (fun root ->
    let acc = make_acc root in
    Obs.persist_response_content
      ~keeper_name
      ~trajectory_acc:(Some acc)
      ~turn:7
      sample_content;
    let entries = thinking_lines root in
    check int "three reasoning blocks recorded" 3 (List.length entries);
    let kinds =
      List.map (fun (e : Trajectory.withheld_thinking_entry) -> e.reasoning_kind) entries
    in
    check
      bool
      "kinds cover thinking, details, redacted"
      true
      (kinds
       = [ Trajectory.Thinking_block
         ; Trajectory.Reasoning_details
         ; Trajectory.Redacted_thinking
         ]);
    List.iter
      (fun (e : Trajectory.withheld_thinking_entry) ->
         check int "every entry carries the hook turn" 7 e.turn)
      entries;
    check
      bool
      "block_index preserves the position in the content list"
      true
      (List.map (fun (e : Trajectory.withheld_thinking_entry) -> e.block_index) entries
       = [ 1; 2; 3 ]))
;;

let test_char_counts_are_metadata_only () =
  with_temp_masc_root (fun root ->
    let acc = make_acc root in
    Obs.persist_response_content
      ~keeper_name
      ~trajectory_acc:(Some acc)
      ~turn:1
      sample_content;
    match thinking_lines root with
    | [ thinking; details; redacted ] ->
      check
        int
        "thinking char_count matches the hidden text length"
        (String.length hidden_thinking)
        thinking.char_count;
      check
        int
        "details char_count matches the joined detail text"
        (String.length hidden_details)
        details.char_count;
      check
        int
        "redacted block does not leak its length"
        0
        redacted.char_count
    | entries -> fail (Printf.sprintf "expected 3 entries, got %d" (List.length entries)))
;;

let test_whitespace_details_and_text_blocks_record_nothing () =
  with_temp_masc_root (fun root ->
    let acc = make_acc root in
    Obs.persist_response_content
      ~keeper_name
      ~trajectory_acc:(Some acc)
      ~turn:2
      [ T.Text "plain"
      ; T.ReasoningDetails { reasoning_content = Some " \n " ; details = [] }
      ];
    check int "nothing recorded" 0 (List.length (thinking_lines root)))
;;

let test_no_accumulator_is_a_noop () =
  with_temp_masc_root (fun root ->
    Obs.persist_response_content
      ~keeper_name
      ~trajectory_acc:None
      ~turn:3
      sample_content;
    check int "no accumulator, no entries" 0 (List.length (thinking_lines root)))
;;

(* CoT privacy: walk every byte persisted under the masc root and prove the
   hidden strings never reached disk. *)
let test_persisted_bytes_never_contain_reasoning_text () =
  with_temp_masc_root (fun root ->
    let acc = make_acc root in
    Obs.persist_response_content
      ~keeper_name
      ~trajectory_acc:(Some acc)
      ~turn:4
      sample_content;
    let contains ~needle haystack =
      let n = String.length needle
      and h = String.length haystack in
      let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
      go 0
    in
    let rec files path =
      if Sys.is_directory path
      then
        Sys.readdir path
        |> Array.to_list
        |> List.concat_map (fun n -> files (Filename.concat path n))
      else [ path ]
    in
    let read_file path =
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    let all = files root in
    check bool "at least one trajectory file persisted" true (all <> []);
    List.iter
      (fun path ->
         let bytes = read_file path in
         List.iter
           (fun hidden ->
              check
                bool
                (Printf.sprintf "%s never reaches disk (%s)" hidden (Filename.basename path))
                false
                (contains ~needle:hidden bytes))
           [ hidden_thinking; hidden_details; hidden_redacted ])
      all)
;;

let () =
  run
    "keeper_thinking_observation"
    [ ( "typed reasoning observation pipe"
      , [ test_case
            "one metadata entry per reasoning block"
            `Quick
            test_records_one_entry_per_reasoning_block
        ; test_case "char counts are metadata only" `Quick test_char_counts_are_metadata_only
        ; test_case
            "whitespace details and text blocks record nothing"
            `Quick
            test_whitespace_details_and_text_blocks_record_nothing
        ; test_case "no accumulator is a no-op" `Quick test_no_accumulator_is_a_noop
        ; test_case
            "persisted bytes never contain reasoning text"
            `Quick
            test_persisted_bytes_never_contain_reasoning_text
        ] )
    ]
;;
