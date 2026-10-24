---
name: onepassword
description: Read the installed 1Password connector's safe account connection state.
---

# 1Password connection

Search for `onepassword_status` and invoke it with `{}`. The host supplies your
caller identity; never construct a `lane_call` envelope yourself.

This development version reports account connection state only. It does not yet
perform browser sign-in. `connected` describes the OAuth account connection;
`browser_login_available` separately describes whether browser login is usable.
Do not interpret a connected account as an approved login or a website session.

If configuration or reconnection is needed, tell the operator the safe phase.
Connection controls and approval links belong to the authenticated operator
surface. Never ask for a password, OTP, token, integration key, authorization URL
or approval link in chat. Never read backend secret files or use shell commands
to obtain them. Continue independent work while login-dependent work waits.
