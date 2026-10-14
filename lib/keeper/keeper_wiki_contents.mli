(** The wiki table of contents a Keeper turn carries (RFC
    keepers-see-the-wiki-table-of-contents).

    The turn reads it once at its start, from the pages through
    {!Tool_wiki.read_index_entries}, not from [index.md]. The runtime.toml
    switch [wiki_contents.enabled] (default on) is read here, so every place
    that builds a Keeper turn's context — the autonomous turn, the direct
    turn and the dashboard preview — agrees on whether the wiki is listed. *)

type t =
  | Off
      (** [wiki_contents.enabled] is false, or the caller observed nothing:
          the wiki is not listed and no paragraph is carried. *)
  | Listed of Wiki_journal.entry list
      (** One entry per wiki file in name order; [[]] for no page. *)
  | Unlisted of string
      (** Why the wiki directory could not be listed. Log text only; it does
          not reach the model. *)

val observe : base_path:string -> t
(** [Off] when the switch is off, without touching the wiki directory.
    Otherwise the listing of [<base_path>/.masc/wiki]. Reads the filesystem. *)
