(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val dashboard_dev_token_path : string -> string
(** [<base_path>/.masc/auth/dashboard.token] — the canonical
    dashboard dev-token file written on boot. *)

val ensure_dashboard_dev_token : string -> (string, string) result
(** Idempotent boot helper: returns the canonical dashboard dev token
    string, generating + persisting one to {!dashboard_dev_token_path}
    on first call. [Error msg] when the auth dir is unwritable. Exposed
    so the dashboard-keeper-routes test can drive the boot path directly. *)

val git_remote_to_web_url : string -> string option
(** Normalise a git remote string into a browsable https URL
    (e.g. [git@github.com:o/r.git] / [ssh://git@github.com/o/r.git] /
    [https://github.com/o/r.git] -> [https://github.com/o/r]). Returns
    [None] for empty or unrecognised shapes rather than guessing.
    Exposed for unit testing; surfaced on the worktree-status payload as
    [web_url]. *)
