open Masc_tui_types
let read = Masc_tui_render_prim.models_account_reading ~provider:"codex_a"
let () =
  let check = Alcotest.(check (pair (option string) (list string))) in
  check "unobserved is visible" (None, ["Account emails: not yet read"]) (read Account_emails_unread);
  check "failure is retained" (None, ["Account emails unread: permission denied"])
    (read (Account_emails_failed "permission denied"));
  check "partial read retains exact provider identity and decode warning"
    (Some "owner@example.org", ["Account emails: 2 rows this build cannot read"])
    (read (Account_emails_read {emails=["codex_other", "other@example.org"; "codex_a", "owner@example.org"];unreadable_rows=2}));
  check "successful absent identity is distinct" (None, [])
    (read (Account_emails_read {emails=["other", "other@example.org"]; unreadable_rows=0}))


let () =
  let check = Alcotest.(check (pair (option string) (list string))) in
  let state = create_state ~workspace:"test" ~port:8935 ~refresh_interval:60. () in
  (* The same provider id is loaded with home A while the source row names B. *)
  state.overview_account_emails <- Account_emails_read {
    emails = ["codex_a", "loaded-a@example.org"]; unreadable_rows = 0 };
  let metadata : Masc_tui_runtime_config_view.metadata = {
    source_revision="source-b"; validation=Checked {valid=true;schema_version=1;
      current_schema_version=1;forward_schema=false;issues=[]};
    routing=Routing_active; routing_requires_restart=false; keeper=Not_configured;
    keeper_requires_restart=false; configured_count=0; pending_keys=[];
    applied_keys=[]; preempted_keys=[] } in
  let source emails = Some {rcv_path="runtime.toml";
    rcv_source_text="[providers.codex_a]\naccount-home = \"/source-b\"\n";
    rcv_rows=[];rcv_metadata=metadata;rcv_account_emails=emails} in
  let read () = Masc_tui_render_prim.models_source_account_reading
    ~provider:"codex_a" state.runtime_config_view in
  state.runtime_config_view <- source (Ok (Masc_tui_account_login.Email_rows {rows=["codex_a", Email "source-b@example.org"]; unattributed=0}));
  check "same provider id cannot join loaded home A to source home B"
    (Some "source-b@example.org", []) (read ());
  state.runtime_config_view <- source (Error "source account evidence unavailable");
  check "missing source evidence cannot fall back to loaded A"
    (None, ["Account emails unread: source account evidence unavailable"]) (read ());
  state.runtime_config_view <- source (Ok (Masc_tui_account_login.Email_rows {rows=["codex_a", Email "source-b@example.org"]; unattributed=1}));
  check "source partial warning retains source email"
    (Some "source-b@example.org", ["Account emails: 1 rows this build cannot read"]) (read ());
  let success = `Assoc ["integration_id", `String "codex_other";
    "state", `String "read"; "email", `String "other@example.org"] in
  List.iter (fun (cause, note) ->
    let failed = `Assoc ["integration_id", `String "codex_a";
      "state", `String "not_read"; "cause", `String cause] in
    let reading = Masc_tui_account_login.account_emails_of_document
      (`Assoc ["account_emails", `List [failed; success]]) in
    state.runtime_config_view <- source (Ok reading);
    check ("source provider cause remains visible: " ^ cause) (None, [note]) (read ());
    check "another provider's failure does not discard a successfully read email"
      (Some "other@example.org", [])
      (Masc_tui_render_prim.models_source_account_reading
        ~provider:"codex_other" state.runtime_config_view))
    ["source_unavailable", "Account email unread: login file unavailable";
     "source_unrecognized", "Account email unread: unrecognized login file";
     "invalid_email", "Account email unread: invalid email";
     "not_reported", "Account email: not reported by the client";
     "environment_credential", "Account email: environment credential"];
  state.runtime_config_view <- source (Ok (Masc_tui_account_login.account_emails_of_document
    (`Assoc ["account_emails", `List [success]])));
  check "absent provider evidence stays distinct from unread source" (None, []) (read ());
  state.runtime_config_view <- source (Ok (Masc_tui_account_login.account_emails_of_document
    (`Assoc ["account_emails", `List [`Assoc ["integration_id", `String "codex_a";
      "state", `String "not_read"; "cause", `String "future_cause"]]])));
  check "unknown cause remains visibly unrecognized"
    (None, ["Account emails: 1 rows this build cannot read"]) (read ())
