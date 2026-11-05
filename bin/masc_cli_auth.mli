(* HIGH-RISK-UNREVIEWED: this command writes the first records of a
   multi-account installation and prints the one link that lets the first
   Admin in. *)

(** [masc auth bootstrap]: activates a multi-account installation on a base
    path where no server runs (design 5.1-1, 8.4, plan B3d-1).

    The command takes the BasePath lease, so a running server, another
    activation, or a server that starts meanwhile waits on the lease or is
    refused. It reads the base URL of the server before anything is written,
    then runs {!Authz_activation.activate} with the auth settings a server
    would read from the environment, and prints the invitation link
    [<base url>/accounts/invite#<token>] once on standard output. The token is
    in the fragment, so a browser does not send it to the server in the URL
    (design 5.1-4). It is printed nowhere else.

    Returns the exit code: [0] once the link is printed, [1] otherwise, with
    the reason on standard error. *)
val bootstrap : base_path:string -> external_store:string -> int
