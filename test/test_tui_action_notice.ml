module Notice = Masc_tui_action_notice

let require condition description = if not condition then failwith description
let visible state now = Notice.rejection state ~now ~window:12.
let some = function Some value -> value | None -> failwith "expected rejection"

let () =
  let csi = ("terminal sequence", 10.) in
  let initial = Notice.set_ordinary Notice.empty (Some csi) in
  require (Notice.ordinary initial = Some csi) "ordinary notice is set";
  require (Notice.ordinary_visible initial ~now:22. ~window:12. = Some csi)
    "ordinary notice retains its existing time window";
  require (Notice.ordinary_visible initial ~now:22.1 ~window:12. = None)
    "ordinary notice expires normally";
  let failed = Notice.reject initial Paste_rejected ~now:10. ~window:12. in
  let first = some (visible failed 1000.) in
  require (Option.get (Notice.ordinary failed) == csi)
    "adding a rejection preserves the CSI tuple identity";
  let csi_held = Notice.start_csi failed in
  require (Notice.ordinary_is_csi csi_held)
    "the original CSI ordinary tuple retains its identity";
  require (Notice.preferred csi_held ~existing_action:true ~now:10. ~window:12.
           = Notice.No_preferred)
    "existing action feedback retains priority over CSI and rejection";
  require (Notice.preferred csi_held ~existing_action:false ~now:10. ~window:12.
           = Notice.Csi_recovery)
    "CSI recovery takes priority over rejection when no action is displayed";
  require (Notice.recovery_slot csi_held ~now:10. ~window:12.
             ~csi_fits:true ~rejection_fits:true = Notice.Csi_recovery)
    "a separate slot gives active CSI priority over a rejection";
  require (Notice.recovery_slot csi_held ~now:10. ~window:12.
             ~csi_fits:false ~rejection_fits:true = Notice.No_preferred)
    "an unfitted CSI does not consume or replace the pending rejection";
  (match Notice.recovery_slot failed ~now:10. ~window:12.
           ~csi_fits:true ~rejection_fits:true with
   | Notice.Rejection notice ->
       require (Notice.same_rejection first notice) "a fitted rejection keeps its identity"
   | Notice.No_preferred | Notice.Csi_recovery -> failwith "expected rejection slot");
  require (Notice.recovery_slot failed ~now:10. ~window:12.
             ~csi_fits:true ~rejection_fits:false = Notice.No_preferred)
    "an unfitted rejection has no presentation authority";
  (match Notice.preferred failed ~existing_action:false ~now:10. ~window:12. with
   | Notice.Rejection notice ->
       require (Notice.same_rejection first notice)
         "a rejection can be offered when no action is displayed"
   | Notice.No_preferred | Notice.Csi_recovery -> failwith "expected rejection preference");
  require (Notice.preferred failed ~existing_action:true ~now:10. ~window:12.
           = Notice.No_preferred
           && Notice.same_rejection first (some (visible failed 1000.)))
    "existing action feedback delays, but cannot erase, the rejection";
  let csi_replaced = Notice.set_ordinary csi_held (Some ("later status", 11.)) in
  require (Notice.csi_active csi_replaced && not (Notice.ordinary_is_csi csi_replaced)
           && Notice.same_rejection first (some (visible csi_replaced 1000.)))
    "replacing ordinary feedback preserves active CSI and the pending rejection";
  (* The zero is opaque so the compiler cannot fold the sum into the constant
     tuple [csi] and share it: the fixture must be a distinct allocation. *)
  let equal_csi = (fst csi, snd csi +. Sys.opaque_identity 0.) in
  require (equal_csi = csi && not (equal_csi == csi)) "fixture has equal content and distinct identity";
  let csi_replaced = Notice.set_ordinary csi_held (Some equal_csi) in
  require (not (Notice.ordinary_is_csi csi_replaced))
    "a later ordinary notice with identical contents is not the old CSI notice";
  let csi_replaced = Notice.set_ordinary csi_held (Some ("later status", 11.)) in
  let csi_ended = Notice.end_csi csi_replaced in
  require (not (Notice.csi_active csi_ended)
           && Notice.ordinary csi_ended = Some ("later status", 11.))
    "ending CSI cannot clear a newer ordinary notice";
  let replaced_ordinary = Notice.set_ordinary failed (Some ("async result", 11.)) in
  require (Notice.same_rejection first (some (visible replaced_ordinary 1000.)))
    "an async ordinary result cannot erase an unpresented rejection";
  let cleared_ordinary = Notice.set_ordinary replaced_ordinary None in
  require (Notice.same_rejection first (some (visible cleared_ordinary 1000.)))
    "clearing the ordinary footer cannot erase an unpresented rejection";
  let input = Notice.after_input failed ~input_seen:true ~operator_input:true ~currently_visible:None ~now:10. ~window:12. in
  require (Notice.ordinary input = None && Notice.same_rejection first (some (visible input 1000.)))
    "input before presentation clears only ordinary feedback";
  let weaker = Notice.reject input Input_rejected ~now:1000. ~window:12. in
  require (Notice.same_rejection first (some (visible weaker 1000.)))
    "a later input rejection cannot replace an unpresented paste rejection";
  let newer = Notice.reject weaker Paste_rejected ~now:1000. ~window:12. in
  let second = some (visible newer 1000.) in
  require (not (Notice.same_rejection first second))
    "the same kind of new rejection has a new generation";
  let stale = Notice.presented newer first ~at:1000. ~input_pending:false in
  require (Notice.same_rejection second (some (visible stale 2000.)))
    "an old presentation cannot start a new rejection's lifetime";
  let draining = Notice.presented newer second ~at:1000. ~input_pending:true in
  let draining = Notice.after_input draining ~input_seen:true ~operator_input:true ~currently_visible:None ~now:1000. ~window:12. in
  require (Notice.same_rejection second (some (visible draining 2000.)))
    "input buffered before presentation cannot acknowledge it";
  let hidden = Notice.after_drain draining ~at:2000. ~input_pending:false ~currently_visible:None in
  require (Notice.same_rejection second (some (visible hidden 3000.)))
    "draining after the notice disappears makes it pending again";
  let draining = Notice.presented hidden second ~at:3000. ~input_pending:true in
  let shown = Notice.after_drain draining ~at:4000. ~input_pending:false ~currently_visible:(Some second) in
  require (Notice.same_rejection second (some (visible shown 4012.)))
    "the visible lifetime starts after buffered input drains";
  require (visible shown 4012.1 = None) "a presented notice expires normally";
  let protocol = Notice.after_input shown ~input_seen:true ~operator_input:false ~currently_visible:(Some second) ~now:4001. ~window:12. in
  require (Notice.same_rejection second (some (visible protocol 4001.)))
    "a protocol reply cannot acknowledge the notice";
  let hidden_again = Notice.after_input shown ~input_seen:false ~operator_input:false ~currently_visible:None ~now:4001. ~window:12. in
  require (Notice.same_rejection second (some (visible hidden_again 10000.)))
    "an idle turn hidden by another surface makes the notice pending again";
  let dismissed_hidden = Notice.after_input shown ~input_seen:true ~operator_input:true ~currently_visible:None ~now:4001. ~window:12. in
  require (Notice.same_rejection second (some (visible dismissed_hidden 10000.)))
    "a key on an overlay cannot dismiss a notice hidden underneath it";
  let dismissed = Notice.after_input shown ~input_seen:true ~operator_input:true ~currently_visible:(Some second) ~now:4001. ~window:12. in
  require (visible dismissed 4001. = None) "the next operator input can dismiss a shown notice";
  let expired = Notice.after_input shown ~input_seen:false ~operator_input:false ~currently_visible:None ~now:4012.1 ~window:12. in
  require (visible expired 4012.1 = None) "an expired notice does not become pending again"
