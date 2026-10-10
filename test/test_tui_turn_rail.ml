(** The bracket a turn draws down the left margin.

    A chat pane interleaves one keeper's turn with broadcasts, journal commits
    and other turns on a single clock, and nothing said which rows belonged to
    which turn. Worse, a turn's reasoning, tool calls and skills sat at the
    same depth as its reply -- same column, same indent -- so what a turn did
    read as a sibling of what it said.

    These check the rows [visible_rows] actually returns. A classifier that is
    right while nothing draws it proves nothing about the pane. *)

open Alcotest
module Layout = Masc_tui_message_layout

let entry ?(turn_rail = Layout.Rail_none) ?(style = Layout.Keeper)
    ?(role = "keeper.one") body : Layout.entry =
  { delivery_state = None; style
  ; body_presentation = Layout.Source_body
  ; timestamp = "01:41:00"
  ; timeline_bucket = None
  ; diagnostics = []
  ; speaker = role
  ; role_label = Layout.align_role_label ~style role
  ; role_label_mark_cells = Layout.role_label_mark_cells ~style ()
  ; request_label = ""
  ; body
  ; journal = []
  ; markdown_source = Layout.Markdown_streaming
  ; turn_rail
  ; action = Layout.Action_none
  }
;;

let body_rows ?(inner_width = 60) entry =
  Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width ~height:40
    [ entry ]
  |> List.filter (fun (row : Layout.row) -> row.kind = Layout.Body)
;;

let test_only_the_first_row_carries_the_action () =
  let rows =
    body_rows ~inner_width:40
      { (entry ~turn_rail:Layout.Rail_says (String.make 200 'x')) with
        Layout.action = Layout.Action_unfold_argument
      }
  in
  match rows with
  | [] -> failwith "no body row"
  | first :: rest ->
      check bool "the first row is pressable" true
        (first.Layout.action = Layout.Action_unfold_argument);
      List.iter
        (fun (row : Layout.row) ->
          check bool "and no continuation is" true
            (row.Layout.action = Layout.Action_none))
        rest
;;

(* Which of the rail's two ordinary pieces a row takes is decided by what the
   row is, not by how many rows its turn had. Reading [Layout.all_styles]
   rather than a list of its own: a style added without a decision here would
   otherwise be silently sorted with the speech. *)
let test_work_and_speech_split_the_same_way_for_every_style () =
  let work, speech =
    List.partition
      (fun style ->
        Layout.rail_for_style ~work:Layout.Rail_does ~speech:Layout.Rail_says
          style
        = Layout.Rail_does)
      Layout.all_styles
  in
  check (list bool) "reasoning, tools and skills are the turn's work"
    [ true; true; true; true; true; true ]
    (* [mem], not [memq]: a [Skill] tone is a block, and the ones written here
       are not the ones the list holds. *)
    (List.map (fun style -> List.mem style work)
       [ Layout.Tool
       ; Layout.Thinking
       ; Layout.Skill Layout.Skill_live
       ; Layout.Skill Layout.Skill_settled
       ; Layout.Skill Layout.Skill_attention
       ; Layout.Skill Layout.Skill_failure
       ]);
  check int "and everything else is what the turn says" 7 (List.length speech)
;;

(* A lone row of work still hangs off its turn. This is the arm the pane lost
   when an autonomous turn stopped writing an empty reply beside its calls:
   with two rows the turn drew a bracket, with one it drew nothing at all. *)
let test_a_lone_row_keeps_work_and_drops_speech () =
  check bool "a lone tool block is still work" true
    (Layout.rail_for_style ~work:Layout.Rail_does ~speech:Layout.Rail_none
       Layout.Tool
     = Layout.Rail_does);
  check bool "a lone utterance draws nothing" true
    (Layout.rail_for_style ~work:Layout.Rail_does ~speech:Layout.Rail_none
       Layout.Keeper
     = Layout.Rail_none)
;;

let () =
  run "tui turn rail"
    [ ( "glyphs"
      , [ test_case "work and speech split the same way for every style" `Quick
            test_work_and_speech_split_the_same_way_for_every_style
        ; test_case "a lone row keeps work and drops speech" `Quick
            test_a_lone_row_keeps_work_and_drops_speech
        ;] )
    ; ( "geometry"
      , [] )
    ; ( "the bracket"
      , [ test_case "only the first row carries the action" `Quick
            test_only_the_first_row_carries_the_action
        ;] )
    ]
;;
