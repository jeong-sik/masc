module Presented = Masc_tui_presented

let require condition description =
  if not condition then failwith description

let () =
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
