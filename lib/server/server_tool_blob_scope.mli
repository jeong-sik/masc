(** What the tool blob sweep reads (RFC-0499 §5.3). Each name comes from the
    module that makes it, so a renamed constant breaks this module's build.

    Stores whose files hold references the scan does not read stay
    unclassified, as do names no code makes. A sweep record that names an
    unclassified entry has no deletable blob. *)

val scope : Tool_blob_maintenance.scope
