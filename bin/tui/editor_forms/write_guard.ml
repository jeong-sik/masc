module T = Masc_tui_types

(* A write the guard refuses here is not sent, and is said as kept back
   under its own name (RFC §2). *)
let workspace_write_ready (state : T.state) ~request =
  match T.write_authority_refusal state state.T.workspace_authority with
  | None -> true
  | Some refusal ->
      Masc_tui_transport.Request_notice.report_withdrawn state ~request refusal;
      false
