open Alcotest

module Composer = Masc_tui_composer
module Projection = Masc_tui_composer_projection
module Tui_types = Masc_tui_types

let keeper : Tui_types.keeper =
  { k_name = "analyst"
  ; k_trace_id = "trace-current"
  ; k_paused = false
  ; k_current_task_id = None
  ; k_total_turns = 0
  ; k_total_tokens = 0
  ; k_total_cost_usd = 0.0
  ; k_last_turn_ts = ""
  ; k_compaction_count = 0
  ; k_last_proactive_outcome = "never"
  ; k_created_at = "2026-08-25T00:00:00Z"
  ; k_updated_at = "2026-08-25T00:00:00Z"
  }

let state () =
  Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let target_testable =
  testable
    (fun formatter -> function
       | Composer.No_target -> Format.pp_print_string formatter "no_target"
       | Composer.Ready keeper_name ->
           Format.fprintf formatter "ready(%s)" keeper_name
       | Composer.Unreachable { keeper; reason } ->
           Format.fprintf formatter "unreachable(%s, %s)" keeper reason)
    ( = )

let focus_testable =
  testable
    (fun formatter -> function
       | Composer.Unfocused -> Format.pp_print_string formatter "unfocused"
       | Composer.Focused -> Format.pp_print_string formatter "focused")
    ( = )

let test_no_selected_keeper_has_no_target () =
  let composer = Projection.of_state (state ()) in
  check target_testable "no target" Composer.No_target composer.target

let test_selected_keeper_is_ready () =
  let state = state () in
  state.keepers <- [ keeper ];
  let composer = Projection.of_state state in
  check target_testable "selected roster member" (Composer.Ready "analyst")
    composer.target

let test_unread_roster_keeps_the_selected_name () =
  let state = state () in
  state.keepers <- [ keeper ];
  state.keepers_error <- Some "metadata read failed";
  let composer = Projection.of_state state in
  check target_testable "unread roster"
    (Composer.Unreachable
       { keeper = "analyst"; reason = "keeper list unread" })
    composer.target

let test_focus_and_draft_are_projected_together () =
  let state = state () in
  state.keepers <- [ keeper ];
  let unfocused = Projection.of_state state in
  check focus_testable "initially unfocused" Composer.Unfocused
    unfocused.focus;
  check string "initially empty" "" unfocused.draft;
  state.composer_focused <- true;
  Buffer.add_string state.msg_input "draft for analyst";
  let focused = Projection.of_state state in
  check focus_testable "focused" Composer.Focused focused.focus;
  check string "draft" "draft for analyst" focused.draft

let count_complete_composer_records module_path =
  let count = ref 0 in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.Parsetree.pexp_desc with
           | Parsetree.Pexp_record (fields, _) ->
               let names =
                 List.map
                   (fun ({ Location.txt; _ }, _) -> Ast_grep.longident_leaf txt)
                   fields
               in
               if
                 List.for_all
                   (fun name -> List.mem name names)
                   [ "target"; "focus"; "draft" ]
               then incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    }
  in
  iterator.structure iterator (Ast_grep.parse_implementation_or_fail module_path);
  !count

let production_bin_implementations () =
  let bin_dir = Filename.concat (Ast_grep.source_root ()) "bin" in
  Sys.readdir bin_dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".ml")
  |> List.sort String.compare
  |> List.map (Filename.concat bin_dir)

let test_state_projection_has_one_structural_owner () =
  let owner =
    Filename.concat (Ast_grep.source_root ())
      "bin/masc_tui_composer_projection.ml"
  in
  check int "projection owns one complete Composer.t record" 1
    (count_complete_composer_records owner);
  let unexpected =
    production_bin_implementations ()
    |> List.filter (fun module_path -> not (String.equal module_path owner))
    |> List.filter_map (fun module_path ->
      let count = count_complete_composer_records module_path in
      if count = 0 then None else Some (module_path, count))
  in
  let unexpected_count =
    List.fold_left (fun total (_, count) -> total + count) 0 unexpected
  in
  let unexpected_files =
    unexpected
    |> List.map (fun (module_path, count) ->
      Printf.sprintf "%s (%d)" (Filename.basename module_path) count)
    |> String.concat ", "
  in
  check int
    (if String.equal unexpected_files "" then
       "all other production bin modules have no reconstruction"
     else "unexpected Composer.t reconstructions: " ^ unexpected_files)
    0 unexpected_count;
  check int "key router calls the projection owner" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui.ml"
       ~binding_name:"handle_composer_key"
       ~callee:"Composer_projection.of_state");
  List.iter
    (fun binding_name ->
       check int (binding_name ^ " calls the projection owner") 1
         (Ast_grep.count_calls_in_value_binding
            ~module_path:"bin/masc_tui_render.ml" ~binding_name
            ~callee:"Composer_projection.of_state"))
    [ "composer_line"; "composer_cursor" ]

let () =
  run "tui-composer-projection"
    [ ( "state projection"
      , [ test_case "no target" `Quick test_no_selected_keeper_has_no_target
        ; test_case "ready target" `Quick test_selected_keeper_is_ready
        ; test_case "unread roster" `Quick
            test_unread_roster_keeps_the_selected_name
        ; test_case "focus and draft" `Quick
            test_focus_and_draft_are_projected_together
        ; test_case "one structural owner" `Quick
            test_state_projection_has_one_structural_owner
        ] )
    ]
