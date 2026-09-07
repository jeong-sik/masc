(** The file changes a keeper made, read back out of the tool-call log.

    {!Keeper_tool_call_log} persists every call with its full input, so the
    exact text an [Edit] replaced and the text it wrote are both still there
    after the turn ends. This module reads one of those rows and answers what
    changed — or says why it could not.

    Nothing here consults [.masc-ide/]. That store keeps addressed code facts
    for an IDE to overlay; this is a projection of the call log itself, which
    is the only place the before/after text survives.

    How far back the answer reaches is the log's retention window, not this
    module's: {!Keeper_tool_call_log.init} prunes at
    [MASC_TOOL_CALL_LOG_RETENTION_DAYS] (30 days by default). Past that the
    change is gone from disk and no projection can recover it. *)

type location =
  | In_repo of {
      repo_id : string;
      relative_path : string;
    }
      (** The file sits inside one of the keeper's repository clones.
          [relative_path] is relative to that clone's root, which is the
          address the same file has in anyone else's checkout. *)
  | In_bundle of { bundle_path : string }
      (** The file sits in the keeper's playground but under no repository
          clone — a scratch script, a note. Real, and not addressable as
          repository code. Kept rather than dropped: a keeper that wrote a
          file did write a file, and a projection that silently omitted it
          would undercount the turn's work. *)
  | At_absolute_path of { path : string }
      (** The write resolver recorded an absolute path. Two live shapes, and
          neither is repository-addressable: a worktree checked out at the
          bundle's own level rather than under [repos/] (see #28968), and a
          write into the operator's own tree, outside any playground.

          Separate from {!In_bundle} because it is not relative to anything —
          40 of 568 changes over 2026-08-22..24 arrive this way, and folding
          them in would have every one of them read as a path under a bundle
          root they do not sit in. *)

type kind =
  | Edited of {
      before : string;
      after : string;
      replace_all : bool;
    }  (** The exact strings the call swapped. *)
  | Written of { content : string }
      (** The whole file body the call wrote. There is no [before]: a write
          replaces the file without reading it, so the call itself never knew
          the previous contents. *)
  | Inserted of {
      line : int;
      text : string;
    }
      (** One line put above [line] (1-based), which is how a memo is left:
          [text] is the comment line as the file received it, composed from
          the call's memo text, its kind and the keeper's name in the file's
          own comment syntax. *)

type t = {
  at : float;  (** Unix time the call was logged. *)
  keeper : string;
  turn : int option;
  task_id : string option;
  execution_id : string option;
  line_evidence : Keeper_file_change_evidence.t option;
      (** Producer-owned actual line ranges from the same execution row.
          Historical rows carry [None]; malformed evidence makes the row
          {!Unreadable} rather than inventing coordinates. *)
  location : location;
  kind : kind;
  succeeded : bool;
      (** Whether the call itself reported success. A failed write is still a
          change the keeper attempted, and reading the attempt is often the
          point, so it is projected with this flag rather than filtered out. *)
}

type unreadable_reason =
  | Input_exceeded_log_budget
      (** The call's arguments serialized past the tool-call log's inline
          budget ([Keeper_tool_call_log.max_output_len], 4,000 bytes), so the
          log kept a truncated preview string in place of the object. The
          change happened and the row records that it happened; the text it
          wrote is not on disk to be read back.

          This is the ordinary fate of a large change, not a defect — measured
          at 10 of 182 file-writing calls on 2026-08-24. It is separated from
          {!Malformed} because the two ask different things of an operator:
          nothing can be done about a change that outgrew the budget, and a
          malformed row means a producer is writing something unexpected. *)
  | Malformed of string
      (** The row claimed a file-writing tool but did not carry what a change
          needs, for a reason the log's own budget does not explain. *)

type classification =
  | Not_a_file_change
      (** The call ran a tool that does not write files, or ran a
          composition-surface tool that carries no descriptor at all. *)
  | File_change of t
  | Unreadable of unreadable_reason
      (** Named rather than dropped: a row that should have projected and did
          not would otherwise be indistinguishable from a read. *)

val classify : Yojson.Safe.t -> classification
(** [classify row] decides what one logged call was.

    The tool's identity comes from the descriptor its route evidence names, so
    the decision is a match over {!Keeper_tool_descriptor.runtime_handler} and
    not over a display name. A row whose descriptor is unknown to this build
    is {!Unreadable}, not a read.

    No base path is needed: a call's resolved target is already relative to
    the keeper's bundle, and where that bundle sits on disk — local or
    Docker — does not change the address of a file inside it. *)

type unreadable_row = {
  ur_location : location option;
      (** The resolved action-radius target when that independent field was
          readable. [None] means this row could belong to any file. *)
  ur_reason : unreadable_reason;
}

type tally = {
  changes : t list;  (** In the order the rows came. *)
  unreadable_rows : unreadable_row list;
      (** File-writing rows that could not become full {!t} values, in source
          order. Kept beside the legacy counts so a file-centric reader can
          distinguish an exact incomplete row from a fleet-wide unknown. *)
  not_file_changes : int;
  over_budget : int;
      (** File changes whose text the log did not keep. A caller that draws
          changes owes its reader this number: without it a turn that wrote
          one small file and three large ones looks like a turn that wrote
          one file. *)
  malformed : int;
}

val empty_tally : tally
(** The tally of no rows. *)

val rows_counted : tally -> int
(** How many rows a tally was folded from: changes, unreadable rows and
    not-file-changes are a partition of what was read, so this is the row count
    without keeping the rows. A caller that reports "n changes out of m calls"
    reads m here rather than measuring the list it no longer holds. *)

val fold_row : tally -> Yojson.Safe.t -> tally
(** Fold one row into a tally. [classify_all] is this over a list; a caller
    reading rows incrementally holds the tally between reads instead. Both
    lists accumulate newest-first — pass the result through {!seal_tally}
    before showing it. *)

val seal_tally : tally -> tally
(** Put a folded tally's lists back in source order. Idempotent it is not:
    call it once, when the fold is finished. *)

val classify_all : Yojson.Safe.t list -> tally
(** [classify_all rows] classifies each row and counts the
    outcomes. The counts are returned rather than logged so a caller can put
    them in its own answer. *)

val for_repo_file : repo_id:string -> relative_path:string -> t list -> t list
(** Exact repository-address filter for a file-centric projection. Bundle and
    absolute writes never match: neither has a repository address, and path
    text alone is not permission to assign one. Order is preserved. *)

val unreadable_for_repo_file :
  repo_id:string -> relative_path:string -> unreadable_row list -> unreadable_row list
(** Exact address filter for incomplete rows whose independent action-radius
    target survived. Rows with no readable target never match. *)

val to_json : t -> Yojson.Safe.t
