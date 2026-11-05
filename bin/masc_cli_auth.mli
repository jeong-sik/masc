(* HIGH-RISK-UNREVIEWED: this command writes the first records of a
   multi-account installation and prints the one link that lets the first
   Admin in. *)

(** [masc auth bootstrap] and [masc auth invite]. *)

(** [masc auth bootstrap]: activates a multi-account installation on a base
    path where no server runs (design 5.1-1, 8.4, plan B3d-1).

    The command takes the BasePath lease, so a running server, another
    activation, or a server that starts meanwhile waits on the lease or is
    refused. Before anything is written it reads [MASC_HTTP_BASE_URL], the
    public address that the person opens, and refuses when it is not an http(s)
    origin with no path; [MASC_HOST] and [MASC_HTTP_PORT] are not read, because
    the server can listen elsewhere. It then runs {!Authz_activation.activate}
    with the anonymous-mutation setting of this process's environment, which a
    server started from the same environment reads, and prints
    {!Authz_activation.link} once on standard output. The link is printed
    nowhere else.

    Returns the exit code: [0] once the link is printed, [1] otherwise, with
    the reason on standard error. *)
val bootstrap : base_path:string -> external_store:string -> int

(** [masc auth invite]: writes one more Admin invitation with
    {!Authz_activation.invite}, under the lease and with the reads of
    {!bootstrap} first, and prints its link once. For a first invitation that
    expired before it was spent, or whose link was lost. Same exit codes. *)
val invite : base_path:string -> int
