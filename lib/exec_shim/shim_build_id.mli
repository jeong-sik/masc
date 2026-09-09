val release : string
(** The MASC release this shim was built from, for example ["0.33.0"]. Comes
    from [dune-project] through the generating rule in this directory, so a
    build never carries a version somebody forgot to stamp. The server
    compares it with its own {!Build_version.current} and names a difference
    [remote_shim_outdated] (RFC-0427 B-3): the 2026-09-05 skew was a shim one
    release behind, and nothing on the wire said so.

    The protocol major stays in the probe's [version] field; this is a
    separate field, so {!Exec_ssh_protocol.major_of_probe} is untouched. *)

val suffix : string
(** A build discriminator appended to the probe's version string (for
    example ["+a1b2c3d4"]). Empty for an in-repo build; the static build
    script stamps the committing sha here, so two artifacts of the same
    protocol are distinguishable through the probe. The numeric prefix
    still carries the major: [{!Exec_ssh_protocol.major_of_probe}] parses
    "3.0.0+anything" as 3. *)
