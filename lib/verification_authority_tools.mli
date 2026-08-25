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

val create_goal_proof : config:Workspace.config -> (t, string) result
(** The Goal proof surface: read and web-fetch rooted at the shared playground
    prefix. A Goal names no producer, so there is no owned tree to bind to and
    no producer set to derive; this root is the same fixed workspace location
    for every Goal. [tool_search_files] is absent — its containment runs
    through a Keeper's sandbox meta, which this surface has none of. *)

val root_layout : t -> (string list, string) result
(** The paths the lookup tools resolve against, listed from disk at review
    time and relative to the ownership root: bounded immediate entries plus
    every checkout returned by the shared checkout-discovery authority.
    Unavailable or partial discovery is [Error], so a caller must defer the
    review instead of turning an incomplete list into absence evidence. *)

val goal_proof_root_layout : t -> (string list, string) result
(** {!root_layout} for a {!create_goal_proof} surface: the producer entries
    under the shared root, without the per-producer checkout scan. That scan
    stops on its reported-checkout budget when walked across every producer at
    once, and the stop is an [Error] — running it here deferred every Goal
    review instead of listing anything. *)

val schemas : t -> Types_core.tool_schema list

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result
