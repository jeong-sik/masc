module Presented = Masc_tui_presented

let require condition description =
  if not condition then failwith description

let () =
  let decide = Presented.decide_unpresented_input in
  require (decide ~frame_presented:false ~external_surface:false Action = Reject_action)
    "an invalidated frame cannot accept a key or pointer";
  require (decide ~frame_presented:false ~external_surface:false Paste = Reject_paste)
    "an invalidated frame cannot accept a paste";
  require (decide ~frame_presented:false ~external_surface:false Protocol = Accept_input)
    "an invalidated frame still accepts protocol replies";
  require (decide ~frame_presented:true ~external_surface:false Action = Accept_input)
    "a presented frame retains its own input policy, including compact quit";
  require (decide ~frame_presented:false ~external_surface:true Action = Accept_input
           && decide ~frame_presented:false ~external_surface:true Paste = Accept_input)
    "independently drawn surfaces retain their input policy";
  let help = Presented.decide_help_input ~external_surface:false in
  require (help ~presented_help:true ~current_help:true Action = Accept_input
           && help ~presented_help:true ~current_help:true Paste = Reject_paste
           && help ~presented_help:true ~current_help:true Protocol = Accept_input)
    "presented Help owns keys and rejects paste without rejecting protocol";
  List.iter (fun (presented_help, current_help) ->
      require (help ~presented_help ~current_help Action = Reject_action
               && help ~presented_help ~current_help Paste = Reject_paste
               && help ~presented_help ~current_help Protocol = Accept_input)
        "both directions of the Help transition reject operator input")
    [false, true; true, false];
  require (help ~presented_help:false ~current_help:false Action = Accept_input
           && help ~presented_help:false ~current_help:false Paste = Accept_input)
    "non-Help ownership keeps its existing admission";
  List.iter (fun (presented_help, current_help) ->
      let external_decision = Presented.decide_help_input ~external_surface:true
          ~presented_help ~current_help in
      require (external_decision Action = Accept_input && external_decision Paste = Accept_input
               && external_decision Protocol = Accept_input)
        "image and machine surfaces retain their own admission")
    [false, false; false, true; true, false; true, true];
  let old = Presented.initial ~approval:"old approval" ~presses:"old zones"
      ~panes:"old panes" ~reader:"old reader" in
  let same = Presented.presented old ~approval:"approval" ~presses:"zones"
      ~panes:"panes" ~reader:"reader" ~owner_changed:false ~input_pending:true in
  require (same.barrier = Presented.Open) "an unchanged owner does not create a barrier";
  let next = Presented.presented old ~approval:"new approval" ~presses:"new zones"
      ~panes:"new panes" ~reader:"new reader" ~owner_changed:true ~input_pending:true in
  require (next.approval = "new approval" && next.presses = "new zones"
           && next.panes = "new panes" && next.reader = "new reader")
    "the whole accepted frame is committed together";
  require (old.reader = "old reader" && old.barrier = Presented.Open)
    "the earlier snapshot remains unchanged";
  let held = Presented.reject next ~paste:false
      |> fun snapshot -> Presented.after_input snapshot ~input_pending:true in
  require (held.barrier = Presented.Held { rejected_input = true; rejected_paste = false })
    "pending input keeps the barrier after a rejection";
  let repainted = Presented.presented held ~approval:"later approval" ~presses:"later zones"
      ~panes:"later panes" ~reader:"later reader" ~owner_changed:false ~input_pending:false in
  require (repainted.barrier = held.barrier) "a repaint cannot release the barrier";
  let rejected_paste = Presented.reject repainted ~paste:true in
  require (rejected_paste.barrier = Presented.Held { rejected_input = true; rejected_paste = true })
    "paste loss remains visible until the caller handles it";
  let drained = Presented.after_input rejected_paste ~input_pending:false in
  require (drained.barrier = Presented.Open) "the barrier ends when all input settles";
  require (rejected_paste.barrier <> drained.barrier) "the pre-release evidence remains immutable";
  let recovery = Presented.reject_recovery drained in
  let recovery_repaint = Presented.presented recovery ~approval:"a" ~presses:"p"
      ~panes:"n" ~reader:"r" ~owner_changed:false ~input_pending:false in
  require (recovery_repaint.barrier = Presented.Open
           && recovery_repaint.recovery = Presented.Rejected_recovery)
    "rejected recovery survives presentation without holding unrelated input";
  require ((Presented.clear_recovery recovery_repaint).recovery = Presented.No_rejected_recovery)
    "tail settlement clears recovery evidence";
  let idle = Presented.presented old ~approval:"a" ~presses:"p" ~panes:"n" ~reader:"r"
      ~owner_changed:true ~input_pending:false in
  require (idle.barrier = Presented.Open) "a transition with no pending input stays open"
