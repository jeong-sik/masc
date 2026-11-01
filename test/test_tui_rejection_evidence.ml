module Notice = Masc_tui_action_notice
module Press = Masc_tui_press
module Hit = Masc_tui_hit

let require condition description = if not condition then failwith description

let () =
  let state = Notice.reject Notice.empty Paste_rejected ~now:0. ~window:12. in
  let notice = match Notice.rejection state ~now:0. ~window:12. with
    | Some notice -> notice | None -> failwith "missing rejection" in
  let registry = Hit.registry () in
  let marker = Hit.mark registry (Press.Press_input_rejection notice)
      (Notice.rejection_text notice) in
  let _, zones = Hit.extract registry [marker] in
  let width = Masc_tui_message_layout.display_width (Notice.rejection_text notice) in
  require (Option.exists (Notice.same_rejection notice)
             (Press.presented_input_rejection ~rows:1 ~cols:width zones))
    "a complete notice inside the frame is evidence";
  require (Press.presented_input_rejection ~rows:0 ~cols:width zones = None)
    "a notice outside the presented rows is not evidence";
  require (Press.presented_input_rejection ~rows:1 ~cols:(width - 1) zones = None)
    "a notice outside the presented columns is not evidence";
  let closing_mark = "\027[=2m" in
  let unclosed = String.sub marker 0 (String.length marker - String.length closing_mark) in
  let _, cut_zones = Hit.extract registry [unclosed] in
  require (Press.presented_input_rejection ~rows:1 ~cols:width cut_zones = None)
    "a mark without its closing boundary is not evidence";
  require (not (Press.press_is_interactive (Press.Press_input_rejection notice)))
    "evidence-only marks are excluded from pointer dispatch";
  require (Press.press_is_interactive (Press.Press_keeper_row "keeper"))
    "ordinary marked targets remain interactive";
  let keeper = Hit.mark registry (Press.Press_keeper_row "keeper") "keeper" in
  let _, combined = Hit.extract registry [marker; keeper] in
  let interactive = Hit.filter Press.press_is_interactive combined in
  require (Hit.target_at interactive ~row:1 ~column:1 = None)
    "a notice cannot consume a pointer event";
  require (Hit.target_at interactive ~row:2 ~column:1 = Some (Press.Press_keeper_row "keeper"))
    "filtering notice evidence preserves other pointer targets";
  require (Option.exists (Notice.same_rejection notice)
             (Press.presented_input_rejection ~rows:2 ~cols:width combined))
    "excluding the notice from pointer dispatch does not erase its presentation evidence"

let () =
  let original = ("quit confirmation", 1.) in
  let confirmation = Notice.arm_quit ~kind:Notice.Quit_key ~ordinary:original in
  let registry = Hit.registry () in
  let marker = Hit.mark registry (Press.Press_quit_confirmation confirmation) (fst original) in
  let _, zones = Hit.extract registry [marker] in
  let width = Masc_tui_message_layout.display_width (fst original) in
  require (Option.exists (Notice.same_quit confirmation)
             (Press.presented_quit_confirmation ~rows:1 ~cols:width zones))
    "a complete in-bounds confirmation grants display evidence";
  require (Press.presented_quit_confirmation ~rows:0 ~cols:width zones = None)
    "an out-of-frame confirmation grants no display evidence";
  require (Press.presented_quit_confirmation ~rows:1 ~cols:(width - 1) zones = None)
    "an out-of-bounds confirmation grants no display evidence";
  let closing_mark = "\027[=2m" in
  let unclosed = String.sub marker 0 (String.length marker - String.length closing_mark) in
  let _, cut_zones = Hit.extract registry [unclosed] in
  require (Press.presented_quit_confirmation ~rows:1 ~cols:width cut_zones = None)
    "a partially drawn confirmation grants no display evidence";
  require (not (Press.press_is_interactive (Press.Press_quit_confirmation confirmation)))
    "confirmation evidence cannot intercept mouse input"

let () =
  let ordinary = ("Quit loses draft and queued work; q again", 1.) in
  let confirmation = Notice.arm_quit ~kind:Notice.Quit_key ~ordinary in
  let other_ordinary = (Sys.opaque_identity (fst ordinary), Sys.opaque_identity 1.) in
  let other = Notice.arm_quit ~kind:Notice.Quit_key ~ordinary:other_ordinary in
  require (not (Notice.same_quit confirmation other)) "the two arms have distinct identities";
  let cols = 10 in
  let registry = Hit.registry () in
  let mark confirmation =
    Press.quit_fragments ~cols confirmation
    |> List.map (fun (target, text) -> Hit.mark registry target text) in
  let lines = mark confirmation in
  let other_lines = mark other in
  let evidence lines ~rows ~cols =
    let _, zones = Hit.extract registry lines in
    Press.presented_quit_confirmation ~rows ~cols zones in
  let rows = List.length lines in
  let present lines = evidence lines ~rows ~cols in
  require (rows >= 3) "the confirmation needs several parts for this case";
  require (Option.exists (Notice.same_quit confirmation) (present lines))
    "all complete parts grant presentation evidence";
  require (present (List.tl lines) = None)
    "a missing first part grants no evidence";
  require (present (List.filteri (fun index _ -> index <> 1) lines) = None)
    "a missing middle part grants no evidence";
  require (present (List.filteri (fun index _ -> index <> rows - 1) lines) = None)
    "a missing last part grants no evidence";
  require (present (List.rev lines) = None)
    "parts in the wrong order grant no evidence";
  require (present (List.mapi (fun index line ->
      if index = 1 then List.nth other_lines index else line) lines) = None)
    "parts of another confirmation grant no evidence";
  let closing_mark = "\027[=2m" in
  let unclosed line = String.sub line 0 (String.length line - String.length closing_mark) in
  require (present (List.mapi (fun index line ->
      if index = 1 then unclosed line else line) lines) = None)
    "an incomplete part grants no evidence";
  require (evidence lines ~rows:(rows - 1) ~cols = None)
    "parts outside the terminal height grant no evidence";
  require (evidence lines ~rows ~cols:(cols + 1) = None)
    "a confirmation from another width grants no evidence";
  List.iter (fun (target, _) ->
      require (not (Press.press_is_interactive target))
        "confirmation parts cannot intercept mouse input")
    (Press.quit_fragments ~cols confirmation)

let () =
  let first_state = Notice.reject Notice.empty Input_rejected ~now:0. ~window:12. in
  let next_state = Notice.reject first_state Input_rejected ~now:0. ~window:12. in
  let rejection = Option.get (Notice.rejection first_state ~now:0. ~window:12.) in
  let other = Option.get (Notice.rejection next_state ~now:0. ~window:12.) in
  let cols = 6 in
  let registry = Hit.registry () in
  let mark notice = Press.rejection_fragments ~cols notice
    |> List.map (fun (target, text) -> Hit.mark registry target text) in
  let lines = mark rejection and other_lines = mark other in
  let rows = List.length lines in
  let evidence lines ~rows ~cols =
    let _, zones = Hit.extract registry lines in
    Press.presented_input_rejection ~rows ~cols zones in
  let present lines = evidence lines ~rows ~cols in
  require (Option.exists (Notice.same_rejection rejection) (present lines))
    "all complete rejection parts grant presentation evidence";
  require (present (List.tl lines) = None)
    "a missing rejection part grants no evidence";
  require (present (List.rev lines) = None)
    "out-of-order rejection parts grant no evidence";
  require (present (List.mapi (fun index line ->
      if index = 1 then List.nth other_lines index else line) lines) = None)
    "parts of a later rejection grant no evidence for the original";
  let closing_mark = "\027[=2m" in
  require (present (List.mapi (fun index line ->
      if index = 1 then String.sub line 0 (String.length line - String.length closing_mark)
      else line) lines) = None)
    "an incomplete rejection part grants no evidence";
  require (evidence lines ~rows:(rows - 1) ~cols = None)
    "a rejection below the frame grants no evidence";
  require (evidence lines ~rows ~cols:(cols + 1) = None)
    "a rejection from another width grants no evidence"
