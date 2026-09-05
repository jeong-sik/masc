(** An explicit pull-request reference, and the GitHub remote it opens in.

    Free text names a PR two ways this reads: a [github.com/<owner>/<repo>/pull/<n>]
    link, which also says which repository, and a [PR-<n>] token, which
    leaves the repository to the surface's scope. A bare [#<n>] is not one --
    "Fix items #3 and #4" is a list, not a link -- so it is never read as a
    PR, and opening it is not a thing this module offers. *)

type t =
  | Pull_url of
      { slug : string  (** [owner/repo], as the link spelt it *)
      ; number : int
      }
  | Pr_token of int

val find : string -> t option
(** The first explicit reference in the text, scanning left to right. *)

val number : t -> int

val github_slug_of_remote : string -> string option
(** [owner/repo] from a registered remote, for GitHub only: other forges
    spell the path differently, and guessing would link to a 404. Accepts
    [git@github.com:owner/repo(.git)] and [https://github.com/owner/repo(.git)]. *)

val pull_url : slug:string -> number:int -> string

val github_pr_url : remote:string -> number:int -> string option
(** [pull_url] for a remote's slug, when the remote is GitHub. *)
