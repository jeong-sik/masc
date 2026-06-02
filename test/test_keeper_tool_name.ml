(** Roundtrip coverage for the keeper-owned tool-name vocabulary.

    Lives on the keeper side of the Tool/Keeper boundary (#19797): the keeper
    subsystem owns the typed vocabulary of its own tools in [Keeper_tool_name],
    while [Tool_name] only carries the [Masc] variant. This test preserves the
    keeper roundtrip coverage that previously lived in test_tool_name.ml. *)

open Masc_mcp

(* Enumerate every variant of [Keeper_tool_name.t]. The wildcard-free match in
   [all] makes the compiler flag this list if a new variant is added without a
   roundtrip assertion. *)
let all : Keeper_tool_name.t list =
  let cover = function
    (* The match below exists only to force exhaustiveness; the returned list is
       what the test actually iterates. *)
    | Keeper_tool_name.Execute
    | Board_comment | Board_comment_vote
    | Board_curation_read | Board_curation_submit
    | Board_get | Board_list | Board_post | Board_search | Board_stats
    | Board_sub_board_create | Board_sub_board_delete | Board_sub_board_get
    | Board_sub_board_list | Board_sub_board_update
    | Board_vote | Broadcast | Context_status
    | Fs_edit | Fs_write | Fs_read | Ide_annotate | Handoff
    | Library_read | Library_search | Memory_search | Memory_write
    | Search_files | Stay_silent
    | Task_claim | Task_create | Task_done | Task_submit_for_verification
    | Task_force_done | Task_force_release
    | Tasks_audit | Tasks_list | Time_now | Tool_search | Tools_list
    | Voice_agent | Voice_listen | Voice_session_end | Voice_session_start
    | Voice_sessions | Voice_speak -> ()
  in
  let names =
    [ Keeper_tool_name.Execute
    ; Board_comment; Board_comment_vote
    ; Board_curation_read; Board_curation_submit
    ; Board_get; Board_list; Board_post; Board_search; Board_stats
    ; Board_sub_board_create; Board_sub_board_delete; Board_sub_board_get
    ; Board_sub_board_list; Board_sub_board_update
    ; Board_vote; Broadcast; Context_status
    ; Fs_edit; Fs_write; Fs_read; Ide_annotate; Handoff
    ; Library_read; Library_search; Memory_search; Memory_write
    ; Search_files; Stay_silent
    ; Task_claim; Task_create; Task_done; Task_submit_for_verification
    ; Task_force_done; Task_force_release
    ; Tasks_audit; Tasks_list; Time_now; Tool_search; Tools_list
    ; Voice_agent; Voice_listen; Voice_session_end; Voice_session_start
    ; Voice_sessions; Voice_speak ]
  in
  List.iter cover names;
  names

let test_roundtrip () =
  List.iter
    (fun v ->
       let s = Keeper_tool_name.to_string v in
       Alcotest.(check (option (of_pp Keeper_tool_name.pp)))
         (Printf.sprintf "roundtrip %s" s)
         (Some v)
         (Keeper_tool_name.of_string s))
    all

let test_unknown_returns_none () =
  Alcotest.(check (option (of_pp Keeper_tool_name.pp)))
    "unknown -> None"
    None
    (Keeper_tool_name.of_string "keeper_nonexistent")

let () =
  Alcotest.run "Keeper_tool_name"
    [ ( "roundtrip",
        [ Alcotest.test_case "all variants roundtrip" `Quick test_roundtrip;
          Alcotest.test_case "unknown -> None" `Quick test_unknown_returns_none
        ] )
    ]
