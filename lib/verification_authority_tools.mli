(** Completion-authority access to one producer's typed read-only filesystem
    descriptors. A Keeper producer receives its metadata-bound Read and Grep;
    a Workspace producer without Keeper runtime metadata receives an
    ownership-root-bound Read. Both receive the shared web-fetch tool so a
    URL left in note evidence (a PR, a CI run) is inspectable by the judge
    itself instead of standing as the producer's claim (masc#28989); its
    boundary guards — http/https only, private-network and localhost targets
    refused, validated redirects, bounded extraction — live in the tool. Descriptor registry drift and unreadable
    producer state reject surface construction. Every dispatched call is
    validated and translated by the same descriptor that was advertised.
    Mutating execution is absent: a verifier has no turn continuation that
    could resume an approved Gate effect. *)


type t

val create :
  config:Workspace.config -> producer:string -> (t, string) result

val root_layout : t -> (string list, string) result
(** The paths the lookup tools resolve against, listed from disk at review
    time and relative to the ownership root: bounded immediate entries plus
    every checkout returned by the shared checkout-discovery authority.
    Unavailable or partial discovery is [Error], so a caller must defer the
    review instead of turning an incomplete list into absence evidence. *)

val schemas : t -> Types_core.tool_schema list

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result
