(** The destination a tool request was captured for: the installation, package
    and tool that were configured when the request was written, and their
    revisions. A consumer keeps it beside the retained request and compares it
    with the destination the configuration names before it sends. *)

type t = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}

val of_runtime : Lane_addon_runtime.tool_request_destination -> t
(** The identity and revisions of the live destination. Its
    [max_reply_bytes] belongs to the live destination and is not kept. *)

val same_semantic : t -> t -> bool
(** Compare installation/package/tool and semantic configuration revision.
    Source bytes, comments and activity do not identify worker inputs.
    Pure comparison only; grants no live authority or retry by itself. *)

val to_json : t -> Yojson.Safe.t
(** An object with exactly the five members, in the order of the fields. *)

val of_json : context:string -> Yojson.Safe.t -> (t, string) result
(** Exactly the five members of {!to_json}, each nonblank text. An error names
    [context] and the field. Whether the installation is configured and
    whether the package and tool are the consumer's own is the consumer's check. *)
