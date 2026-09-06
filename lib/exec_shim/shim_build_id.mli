val suffix : string
(** A build discriminator appended to the probe's version string (for
    example ["+a1b2c3d4"]). Empty for an in-repo build; the static build
    script stamps the committing sha here, so two artifacts of the same
    protocol are distinguishable through the probe. The numeric prefix
    still carries the major: [{!Exec_ssh_protocol.major_of_probe}] parses
    "3.0.0+anything" as 3. *)
