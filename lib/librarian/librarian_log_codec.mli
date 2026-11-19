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

    A fact is written as the snapshot writes it, a mark as a turn log line
    writes it, and the claim of an op that was left out as the answer writes
    it. The fact codec raises [Invalid_argument] on a blank claim, a time that
    is not finite, and a derivation {!Keeper_memory_os_types.derived} refuses.
    A commit whose effects a plan made has none of them. *)

val to_json : Librarian_log.line -> Yojson.Safe.t

(** Every object has exactly its fields. Counts and offsets are not negative,
    a line's [at] is finite, and a Memory id has the shape of one. Text a write carried (a claim, a
    reason, a name) is read as it was written: the reader does not refuse a
    line the writer could have written. *)
val of_json
  :  Yojson.Safe.t
  -> (Librarian_log.line, Keeper_memory_os_types.wire_error) result
