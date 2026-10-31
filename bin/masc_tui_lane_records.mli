(** Quiz-source records ([binding.records]) of a Lane installation TOML.

    A record grants one installation read access to one operator source: a
    board visibility set, a repository's commits and files, the workspace
    wiki, or a repository's merged pull requests (RFC operator-quiz §4.5,
    K3). The host reads [binding.records] itself when the declaration is
    saved; this module parses the entries for display, appends one entry a
    schema form built, and drops one entry by name. All edits are
    line-based insertions and deletions, so comments and unrelated tables
    stay byte-for-byte stable. *)

type record = {
  source_id : string;
  kind : string;
  visibilities : string list;
  repository_id : string option;
  paths : string list;
}
(** One [[binding.records]] entry as the TOML spells it. *)

val parse : string -> (record list, string) result
(** The entries of [text] in file order. No [binding.records] key is no
    entry. Inline bindings and records arrays, and malformed entries, are
    refused with an instruction to edit the raw TOML. *)

val add : string -> Yojson.Safe.t -> (string, string) result
(** Append the entry [json] describes and return the new text. Its fields are
    checked with the host grant validator under an operator-owned assumption
    (closed kind, exact keys per kind, non-blank [source_id], known
    visibilities, repository-relative paths). This does not establish the
    declaration's actual ownership or worker application. Existing duplicate
    IDs and a [source_id] the text already carries are refused. Other TOML
    values and existing entries must compare equal after the insertion. *)

val remove : string -> source_id:string -> (string, string) result
(** Drop exactly one entry named [source_id] and return the new text. Refused
    when any IDs are duplicated, or the name is absent or not addressable.
    The remaining parsed entries and unrelated TOML must compare equal. *)

val item_schema : Yojson.Safe.t
(** The JSON schema the add form renders: [source_id], a closed [kind],
    and the kind's own fields. *)

type t
(** The overlay's working state: its own copy of the TOML, the parsed
    entries, the cursor, and the open add form if any. *)

type event =
  | Updated of t
  | Apply of t * string
      (** The working text changed; the caller writes it into the open
          declaration draft. The overlay stays open. *)
  | Cancel
      (** The overlay closed; the caller drops it. Edits already applied
          stay in the draft. *)

val open_ : title:string -> text:string -> (t, string) result
(** Open the overlay over [text], shown under [title]. Refused when the
    entries do not parse; the raw text stays editable elsewhere. *)

val handle : key:string -> t -> (event, string) result
(** One key. [j]/[k] move, [a] opens the add form, [d] drops the selected
    entry, [Esc]/[q] closes. While the form is open every key goes to it;
    its submit appends the entry and its cancel returns to the list. *)

val insert_text : text:string -> t -> t
(** Pasted text goes to the open add form; without one the state is
    unchanged. *)

val text_entry_open : t -> bool
(** Whether the add form is open and takes typed characters. *)

val text : t -> string
(** The overlay's working copy of the TOML. *)

val title : t -> string
(** The declaration draft this overlay belongs to. *)

val message : t -> string option
(** The last edit result, if any. *)

val lines : t -> string list
(** The overlay as printable rows: the entries, the open form if any, and
    the keys that act here. *)
