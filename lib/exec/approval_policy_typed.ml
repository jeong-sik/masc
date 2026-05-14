(** Approval_policy_typed — GADT-based policy decision.

    Thin wrapper around [Approval_policy.decide]: the GADT gives us a
    total capability extractor, but the rule cascade (destructive-git
    check, write-escape check, trust-level dispatch) is intentionally
    reused without duplication. *)

let decide ~config ~actor cmd raw_simple =
  let overlay = Approval_config.lookup config ~actor in
  let caps = Capability_check_typed.of_command cmd in
  Approval_policy.decide
    { Approval_policy.raw_source = Bin.to_string raw_simple.Shell_ir.bin;
      summary = "Typed dispatch" }
    ~overlay
    ~caps
    ~simple:raw_simple
