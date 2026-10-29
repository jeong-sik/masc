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
  let owner = function true -> Some Presented.Help | false -> None in
  let help ~presented_help ~current_help =
    Presented.decide_panel_input ~external_surface:false
      ~presented_owner:(owner presented_help) ~current_owner:(owner current_help) in
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
      let external_decision = Presented.decide_panel_input ~external_surface:true
          ~presented_owner:(owner presented_help) ~current_owner:(owner current_help) in
      require (external_decision Action = Accept_input && external_decision Paste = Accept_input
               && external_decision Protocol = Accept_input)
        "image and machine surfaces retain their own admission")
    [false, false; false, true; true, false; true, true];
  let old = Presented.initial ~panel_owner:None ~approval:"old approval" ~presses:"old zones"
      ~panes:"old panes" ~reader:"old reader" in
  let same = Presented.presented ~panel_owner:None old ~approval:"approval" ~presses:"zones"
      ~panes:"panes" ~reader:"reader" ~owner_changed:false ~input_pending:true in
  require (same.barrier = Presented.Open) "an unchanged owner does not create a barrier";
  let next = Presented.presented ~panel_owner:None old ~approval:"new approval" ~presses:"new zones"
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
  let repainted = Presented.presented ~panel_owner:None held ~approval:"later approval" ~presses:"later zones"
      ~panes:"later panes" ~reader:"later reader" ~owner_changed:false ~input_pending:false in
  require (repainted.barrier = held.barrier) "a repaint cannot release the barrier";
  let rejected_paste = Presented.reject repainted ~paste:true in
  require (rejected_paste.barrier = Presented.Held { rejected_input = true; rejected_paste = true })
    "paste loss remains visible until the caller handles it";
  let drained = Presented.after_input rejected_paste ~input_pending:false in
  require (drained.barrier = Presented.Open) "the barrier ends when all input settles";
  require (rejected_paste.barrier <> drained.barrier) "the pre-release evidence remains immutable";
  let recovery = Presented.reject_recovery drained in
  let recovery_repaint = Presented.presented ~panel_owner:None recovery ~approval:"a" ~presses:"p"
      ~panes:"n" ~reader:"r" ~owner_changed:false ~input_pending:false in
  require (recovery_repaint.barrier = Presented.Open
           && recovery_repaint.recovery = Presented.Rejected_recovery)
    "rejected recovery survives presentation without holding unrelated input";
  require ((Presented.clear_recovery recovery_repaint).recovery = Presented.No_rejected_recovery)
    "tail settlement clears recovery evidence";
  let idle = Presented.presented ~panel_owner:None old ~approval:"a" ~presses:"p" ~panes:"n" ~reader:"r"
      ~owner_changed:true ~input_pending:false in
  require (idle.barrier = Presented.Open) "a transition with no pending input stays open"

let () =
  let owners = [Presented.Help; About; Context; Agenda; Answering] in
  List.iter (fun source ->
    let decide = Presented.decide_panel_input ~external_surface:false
        ~presented_owner:(Some source) in
    require (decide ~current_owner:(Some source) Paste = Reject_paste)
      "a nontext panel cannot mutate the covered draft";
    require (decide ~current_owner:(Some source) Action = Accept_input)
      "the presented panel retains its own actions";
    require (decide ~current_owner:None Paste = Reject_paste)
      "closing a panel cannot paste into its replacement before presentation";
    List.iter (fun target ->
      if source <> target then
        require (decide ~current_owner:(Some target) Action = Reject_action
                 && decide ~current_owner:(Some target) Paste = Reject_paste
                 && decide ~current_owner:(Some target) Protocol = Accept_input)
          "replacing a nontext panel cannot redirect operator input") owners) owners;
  let before = Presented.initial ~approval:() ~presses:() ~panes:() ~reader:()
      ~panel_owner:(Some Presented.Context) in
  let after = Presented.presented before ~approval:() ~presses:() ~panes:() ~reader:()
      ~panel_owner:(Some Presented.Help) ~owner_changed:true ~input_pending:true in
  require (before.panel_owner = Some Presented.Context
           && after.panel_owner = Some Presented.Help
           && after.barrier = Presented.Held {rejected_input=false; rejected_paste=false})
    "the accepted frame commits the owner with its pending input barrier"

let () =
  let edit = Some Presented.Context_search in
  let decide = Presented.decide_panel_input ~external_surface:false in
  require (decide ~presented_owner:edit ~current_owner:edit Paste = Accept_input)
    "the presented Context search retains its paste input";
  require (decide ~presented_owner:edit ~current_owner:None Paste = Reject_paste
           && decide ~presented_owner:None ~current_owner:edit Paste = Reject_paste)
    "Context search and the covered composer are distinct input owners";
  require (decide ~presented_owner:edit ~current_owner:(Some Context) Action = Reject_action)
    "closing Context search cannot apply a queued key to the inspector"

let () =
  let owner = Presented.{workspace=3; inspector=8; keeper="fixture"} in
  let before = Presented.initial ~approval:() ~presses:() ~panes:() ~reader:()
      ~panel_owner:(Some Presented.Context) in
  let search = Presented.begin_context_search before owner in
  let decide snapshot current owner = Presented.decide_snapshot_input snapshot
      ~external_surface:false ~current_owner:current ~context_search_owner:owner in
  require (decide before (Some Context_search) (Some owner) Action = Reject_action)
    "asynchronous entry into search does not authorize typeahead";
  require (before.context_search = None && search.context_search = Some owner)
    "slash records immutable transition provenance";
  require (Presented.panel_presentation_changed search ~current_owner:(Some Context)
           && Presented.panel_presentation_changed search ~current_owner:(Some Context_search))
    "an unpainted editor transition requires presentation even after empty search or cancel";
  require (decide search (Some Context_search) (Some owner) Action = Accept_input
           && decide search (Some Context_search) (Some owner) Paste = Accept_input)
    "explicit search retains query typeahead and paste";
  List.iter (fun changed ->
    require (decide search (Some Context_search) (Some changed) Action = Reject_action)
      "search cannot borrow a different workspace or inspector")
    [{owner with workspace=4}; {owner with inspector=9}; {owner with keeper="other"}];
  List.iter (fun current ->
    require (decide search current (Some owner) Action = Reject_action
             && decide search current (Some owner) Paste = Reject_paste
             && decide search current (Some owner) Protocol = Accept_input)
      "ending search or changing panels waits for presentation")
    [Some Context; Some Help; None];
  let painted = Presented.presented search ~approval:() ~presses:() ~panes:() ~reader:()
      ~panel_owner:(Some Context_search) ~owner_changed:true ~input_pending:false in
  require (painted.context_search = None && painted.barrier = Open
           && decide painted (Some Context_search) (Some owner) Action = Accept_input)
    "presentation after query input drains retires the grant";
  require (decide painted (Some Context) (Some owner) Action = Reject_action)
    "a second Enter cannot open a result before the post-search frame";
  let returned = Presented.presented search ~approval:() ~presses:() ~panes:() ~reader:()
      ~panel_owner:(Some Context)
      ~owner_changed:(Presented.panel_presentation_changed search ~current_owner:(Some Context))
      ~input_pending:true in
  require (returned.context_search = None
           && returned.barrier = Held {rejected_input=false; rejected_paste=false})
    "a transition back to identical Context still quarantines input arriving during output"
