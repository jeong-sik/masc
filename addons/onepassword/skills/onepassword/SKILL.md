---
name: onepassword
description: Request private 1Password approvals for sign-in in your original Browser session.
---

# 1Password sign-in

Discover `onepassword_status`. The host supplies your caller identity and private
companion grant; never construct `lane_call` yourself. `connected` describes the
account connection, and `browser_login_available` describes configured admission.
Neither proves a website login. An absent or busy configuration reports unavailable.

Use `onepassword_login` with the existing Browser Add-on's `browser_instance_id`,
MASC `tab_id`, HTTPS `website`, and plain `goal` and `reason`. Do not create another
browser to fill credentials. Keep the returned `operation_id`; `onepassword_logins`
can recover your own operation IDs if a reply is lost. A lost start reply is a
reason to inspect existing operations before creating another request.

Ask the operator to open this Add-on's private controls, open the 1Password
approval, and acknowledge that the app opened. The private service checks approval
on the vendor schedule and fills the original tab after a grant. Continue other
work while waiting. If it pauses in `waiting_user`, the operator can confirm their
approval in those controls; never create a replacement request automatically.

Read `onepassword_login_status` for committed state. `fill_submitted` means the
extension submitted a fill; it does not prove website authentication. Use
`onepassword_fill_next` only for an observed next sign-in page of the same login.
Inspect the original Browser after the fill settles. Release the grant with
`onepassword_finish` after the website check, then continue the original task. `onepassword_cancel`
returns a request receipt; inspect status for its settlement. `outcome_unknown`
requires reconciliation of that original operation; never replay its fill or
adopt a replacement Browser session.

Connection controls and approval links belong to the authenticated operator
surface. Never ask for a password, OTP, token, integration key, authorization URL
or approval link in chat. Never read backend secret files or use shell commands
to obtain them. Installed runtime, real-account authentication and durable automatic
Keeper continuation remain unverified in this development version.
