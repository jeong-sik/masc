(** Keeper_goal_repair — detect and repair empty [active_goal_ids].

    When a keeper's [active_goal_ids] is empty, the task filter accepts
    ALL tasks equally, causing claim/release loops.  This module:

    1. Detects keepers with empty [active_goal_ids].
    2. Creates a goal from the keeper's [goal] field (purpose statement).
    3. Assigns the new goal id to [active_goal_ids].

    Two entry points: {!dry_run} (no side effects, returns the audit
    only) and {!run} (actually creates goals + writes meta).  The
    title-derivation helper {!goal_title_of_purpose} is exposed for
    targeted unit-test coverage of its truncation/empty/long
    branches; other internal helpers (find / repair / empty-result
    constant) stay private.

    @since 2.237.0 *)

type repair_action = {
  keeper_name : string;
  goal_id : string;
  goal_title : string;
}
(** One repair entry.  [goal_id] is ["(dry-run)"] for {!dry_run}
    actions and the actual goal id for {!run}. *)

type repair_result = {
  actions : repair_action list;
  skipped : (string * string) list;
        (** [(keeper_name, reason)] — keeper had a non-empty
            [active_goal_ids] or the meta was missing in a way the
            audit pass classified as benign. *)
  errors : (string * string) list;
        (** [(keeper_name, error_message)] — read/write/upsert
            failures.  Do not contain the substring
            ["already has active_"] (that classifies as
            {!field-skipped}). *)
}
(** Concrete record because {!Tool_keeper} field-accesses the lists
    when projecting to the dashboard JSON.  Lists are returned in
    keeper-name order (stable scan order from the [.json] directory
    listing reversed back). *)

val goal_title_of_purpose : string -> string
(** [goal_title_of_purpose purpose] derives the goal title from a
    keeper's purpose statement:
    - empty / whitespace-only purpose → ["(unnamed keeper)"]
    - purpose ≤ 115 chars → ["<purpose> (auto)"]
    - purpose > 115 chars → first 115 chars + ["… (auto)"]

    The returned string never exceeds 130 chars.  Exposed for direct
    unit testing of the truncation contract; production code should
    prefer {!run}/{!dry_run}. *)

val repair_result_to_yojson : repair_result -> Yojson.Safe.t
(** [repair_result_to_yojson r] renders the result as
    {[
      `Assoc [
        ("repaired", `Int <count>);
        ("skipped", `Int <count>);
        ("errors", `Int <count>);
        ("actions", `List [<repair_action>...]);
        ("skipped_details", `List [<{name, reason}>...]);
        ("error_details", `List [<{name, error}>...]);
      ]
    ]}
    The triple count + per-list detail shape is the dashboard
    contract — operator runbooks read these field names verbatim. *)

val dry_run : Coord.config -> repair_result
(** [dry_run config] scans every keeper meta under
    [<masc_dir>/keepers/*.json] and returns the audit without
    creating any goals or writing any meta.  [actions[i].goal_id] is
    always ["(dry-run)"].  Useful for confirming the repair scope
    before committing.  Read-only on disk. *)

val run : Coord.config -> repair_result
(** [run config] scans every keeper meta under
    [<masc_dir>/keepers/*.json] and, for each keeper with empty
    [active_goal_ids]:

    1. Derives a title from the keeper's purpose statement
       (truncated to 115 chars + ["… (auto)"] suffix; falls back to
       ["(unnamed keeper)"] when the purpose is empty).
    2. Calls {!Goal_store.upsert_goal} which must report [`created]
       (an [`updated] response is treated as an error — repair
       expects fresh-goal creation, not an existing-goal collision).
    3. Writes the keeper meta with the new goal id assigned to
       [active_goal_ids].

    Side-effects:
    - Creates one goal record per repaired keeper.
    - Mutates one keeper meta file per repair.
    - Logs at the [Log.Keeper] level (via the goal-store / meta
      writers).

    Error classification: failures whose message starts with
    ["already has active_"] (literal 18-char prefix) are reported
    in {!field-skipped}, not {!field-errors}.  This is a contract
    so operator runbooks distinguish "no-op due to race" from "real
    failure".  Other failures land in {!field-errors}. *)
