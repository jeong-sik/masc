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
type forest

val create :
  config:Workspace.config -> producer:string -> (t, string) result

val root_layout : t -> string list
(** The paths the lookup tools resolve against, listed from disk at review
    time and relative to the ownership root: every immediate entry, plus one
    further level so a checkout under [repos/] names itself. A directory with
    no children is marked, because an empty tree and an unreachable one are
    different findings. [[]] when the root itself cannot be listed. Bounded;
    a truncated listing says so in its last line. *)

val schemas : t -> Types_core.tool_schema list

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result

val create_forest :
  config:Workspace.config -> producers:string list -> (forest, string) result
(** Bind a read-only verifier surface to a closed set of producer trees. The
    filesystem schemas require an exact [producer] chosen from this set; the
    dispatcher refuses every other identity before reaching a tree. *)

val forest_root_layout : forest -> string list
(** {!root_layout} for every producer in the forest, each entry prefixed with
    the producer it belongs to, because the forest dispatcher requires an
    exact producer argument and a bare path would not name one. Bounded
    across the whole forest. *)

val forest_schemas : forest -> Types_core.tool_schema list

val dispatch_forest :
  forest -> name:string -> args:Yojson.Safe.t -> (string, string) result
