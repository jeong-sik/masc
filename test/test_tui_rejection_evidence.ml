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
