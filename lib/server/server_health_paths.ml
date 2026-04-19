(** Issue #8403: SSOT for health probe paths.

    The strings ["/health/live"] and ["/health/ready"] previously
    appeared 9 times across 5 files (HTTP/1 router, H/2 gateway, auth
    public-read whitelist, startup-takeover liveness probe default,
    and bin startup path filter) with no shared constant. Adding a
    third probe (e.g. ["/health/startup"]) required hand-editing all
    five sites, and renaming an existing probe required hand-keeping
    the auth whitelist and startup filter aligned with the router —
    silent drift was the failure mode (whitelist drift hid an
    auth-required probe; route drift broke external monitors).

    Callers should reference these constants by name. The list
    [public] is what the auth/startup filters whitelist; adding a
    new probe means adding a constant *and* appending it here, both
    in the same module, so the whitelist cannot drift from the
    routes.

    @stability Internal *)

let liveness = "/health/live"

let readiness = "/health/ready"

(** All public health probe paths whitelisted for unauthenticated
    read access and treated as benign during startup takeover. *)
let public : string list = [ liveness; readiness ]

let is_public path =
  List.exists (String.equal path) public
