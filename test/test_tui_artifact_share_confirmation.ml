open Alcotest
module Confirmation = Masc_tui_artifact_share_confirmation

let queued_input_cannot_confirm () =
  let confirmation = Confirmation.create () in
  check bool "a new operation is not authorized" false (Confirmation.ready confirmation);
  Confirmation.observe_frame confirmation ~visible:true ~input_pending:true;
  check bool "a queued second key cannot authorize the retry" false (Confirmation.ready confirmation);
  Confirmation.observe_frame confirmation ~visible:false ~input_pending:false;
  check bool "an obscured or incomplete preview cannot authorize the retry" false (Confirmation.ready confirmation);
  Confirmation.observe_frame confirmation ~visible:true ~input_pending:false;
  check bool "the displayed preview and drained input permit a later confirmation" true (Confirmation.ready confirmation);
  Confirmation.observe_frame confirmation ~visible:false ~input_pending:false;
  check bool "an obscured later frame withdraws authority" false (Confirmation.ready confirmation);
  Confirmation.observe_frame confirmation ~visible:true ~input_pending:false;
  Confirmation.withdraw confirmation;
  check bool "moving away from the preview withdraws confirmation authority" false (Confirmation.ready confirmation)

let () = run "TUI artifact share confirmation" ["input authority", [
  test_case "queued and unseen previews cannot authorize a retry" `Quick queued_input_cannot_confirm
]]
