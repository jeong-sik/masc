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
