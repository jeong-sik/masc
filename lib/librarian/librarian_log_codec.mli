(** The wire shape of a commit log line: one JSON object per line
    (RFC librarian-call-only-proposes §8.1).

    {v
    { "line": "started", "at": 1.0, "turn_log": "<32 hex>", "snapshot": "<sha256 hex>",
      "revision": 0, "turn_log_offset": 0, "covered": { … } }
    { "line": "committed", "seq": 1, "at": 2.0,
      "basis": "<sha256 hex>", "after": "<sha256 hex>", "revision": 1,
      "cause": { "kind": "direct", "by": { "kind": "keeper" }, "trace": "…",
                 "write": { "kind": "retract", "id": "sha256:…", "reason": "…" } },
      "effects": { "added": [], "touched": [],
                   "removed": [ { "fact": { … },
                                  "removal": { "kind": "retracted",
                                               "by": { "kind": "keeper" },
                                               "reason": "…" } } ],
                   "not_applied": [], "sources": [] },
      "turn_log": "<32 hex>", "turn_log_offset": 0,
      "covers_through": { "kind": "before_first" }, "covered": { … },
      "working_state": null }
    v}

    An answer and a skip are committed lines whose cause is one of these:

    {v
    { "kind": "read", "question": { "front": "<32 hex>", "back": "<32 hex>" },
      "memory": "shown", "slot": "…", "trace": "…",
      "missing": [ { "line": 120,
                     "parts": [ { "kind": "bundle",
                                  "slice": { "bundle": "<sha256 hex>", "skip": 0, "take": 2 } },
                                { "kind": "chat_bytes", "from": 0, "until": 64 },
                                { "kind": "undecodable_history_line", "offset": 10 },
                                { "kind": "undecodable_external_row", "row": 3 } ] } ] }
    { "kind": "skip", "hole": { "kind": "content_missing", "missing": [ … ] } }
    { "kind": "skip", "hole": { "kind": "unknown_span", "before": { … }, "after": { … } } }
    { "kind": "skip", "hole": { "kind": "line_unreadable", "offset": 240, "sha": "<sha256 hex>" } }
    v}

    A position is [{ "kind": "before_first" }] or
    [{ "kind": "through", "line": 120, "within": … }]. Within a unit read
    whole is [{ "kind": "whole" }], and one read through an item is
    [{ "kind": "item", "store": "history", "at": 1234 }]: [store] is [chat],
    [external], [agent_core], [history] or [internal], and [at] is the
    item's coordinate in that store ({!Librarian_unit.item_name}).

    ["memory"] is ["not_shown"] for a question that showed one item alone.
    A byte or row part is [history_bytes], [internal_bytes], [chat_bytes] or
    [external_rows] with [from] and [until]; an undecodable line of the
    official client's internal file is [undecodable_internal_line].

    A fact is written as the snapshot writes it, a mark and a slice as a turn
    log line writes them, and the claim of an op that was left out as the
    answer writes it. The fact codec raises [Invalid_argument] on a blank
    claim, a time that is not finite, and a derivation
    {!Keeper_memory_os_types.derived} refuses. A commit whose effects a plan
    made has none of them. *)

val to_json : Librarian_log.line -> Yojson.Safe.t

(** A store as a line spells it in an item's name: [chat], [external],
    [agent_core], [history], [internal]. *)
val store_token : Librarian_unit.store -> string

(** The store a line's spelling names, [None] for another word. *)
val store_of_token : string -> Librarian_unit.store option

(** Every object has exactly its fields. Counts and offsets are not negative,
    a line's [at] is finite, a Memory id has the shape of one, and each half
    of a question id is {!Librarian_question_id.half_length} lowercase
    hexadecimal characters. Text a write carried (a claim, a reason, a name)
    is read as it was written: the reader does not refuse a line the writer
    could have written. *)
val of_json
  :  Yojson.Safe.t
  -> (Librarian_log.line, Keeper_memory_os_types.wire_error) result

(** Canonical JSON codec for {!Librarian_effects.removal}, shared with
    {!Librarian_archive} for compacted cold archive sidecars. *)
val removal_to_json : Librarian_effects.removal -> Yojson.Safe.t

val removal_of_json
  :  Yojson.Safe.t
  -> (Librarian_effects.removal, Keeper_memory_os_types.wire_error) result
