(** Structured delta entries for inter-session handoff.

    Produces evidence-pointer structures instead of prose summaries.
    The handoff skill (SSOT per D-0 ADR) consumes these entries
    to create reproducible session-to-session context transfer.

    @since 2.176.0 *)

(** A single delta entry capturing what changed during a session. *)
type delta_entry = {
  since_checkpoint_id: string option;
  (** Base checkpoint identifier (session_id or checkpoint hash).
      [None] if this is the first session with no prior checkpoint. *)

  evidence_refs: evidence_ref list;
  (** Pointers to changes made during this session. *)

  updated_paths: string list;
  (** Files/modules modified during this session. *)

  open_loops: open_loop list;
  (** Incomplete work that the next session must pick up. *)

  decisions: decision list;
  (** Decisions made during this session with rationale. *)

  keeper_state: Keeper_memory_policy.keeper_state_snapshot option;
  (** Final keeper state snapshot (goal/progress/next_items). *)

  created_at: float;
  (** Timestamp when this delta entry was created. *)
}

and evidence_ref = {
  ref_type: string;
  (** One of: "commit", "pr", "issue", "tool_output", "file_change" *)
  ref_id: string;
  (** Identifier: commit SHA, PR number, issue number, etc. *)
  description: string;
  (** Short human-readable summary *)
}

and open_loop = {
  loop_id: string;
  (** Stable identifier for tracking across sessions *)
  description: string;
  status: string;
  (** One of: "blocked", "in_progress", "needs_review" *)
  blocking_reason: string option;
}

and decision = {
  decision_id: string;
  summary: string;
  rationale: string;
}

(* ── Serialization ──────────────────────────────────────── *)

let evidence_ref_to_json (r : evidence_ref) : Yojson.Safe.t =
  `Assoc [
    ("ref_type", `String r.ref_type);
    ("ref_id", `String r.ref_id);
    ("description", `String r.description);
  ]

let open_loop_to_json (l : open_loop) : Yojson.Safe.t =
  `Assoc [
    ("loop_id", `String l.loop_id);
    ("description", `String l.description);
    ("status", `String l.status);
    ("blocking_reason",
      match l.blocking_reason with
      | Some r -> `String r
      | None -> `Null);
  ]

let decision_to_json (d : decision) : Yojson.Safe.t =
  `Assoc [
    ("decision_id", `String d.decision_id);
    ("summary", `String d.summary);
    ("rationale", `String d.rationale);
  ]

let to_json (entry : delta_entry) : Yojson.Safe.t =
  `Assoc [
    ("since_checkpoint_id",
      match entry.since_checkpoint_id with
      | Some id -> `String id
      | None -> `Null);
    ("evidence_refs",
      `List (List.map evidence_ref_to_json entry.evidence_refs));
    ("updated_paths",
      `List (List.map (fun s -> `String s) entry.updated_paths));
    ("open_loops",
      `List (List.map open_loop_to_json entry.open_loops));
    ("decisions",
      `List (List.map decision_to_json entry.decisions));
    ("keeper_state",
      match entry.keeper_state with
      | Some s -> Keeper_memory_policy.keeper_state_snapshot_to_json s
      | None -> `Null);
    ("created_at", `Float entry.created_at);
  ]

(* ── Builder ────────────────────────────────────────────── *)

(** Build a delta entry from keeper state and session metadata.

    [~session_id]: current session identifier
    [~snapshot]: final keeper_state_snapshot (from last [STATE] block)
    [~git_changes]: list of changed file paths (from git diff)
    [~commits]: list of (sha, message) pairs from this session *)
let build
    ?(session_id : string option)
    ?(snapshot : Keeper_memory_policy.keeper_state_snapshot option)
    ?(git_changes : string list = [])
    ?(commits : (string * string) list = [])
    ()
  : delta_entry =
  let evidence_refs =
    List.map (fun (sha, msg) ->
      { ref_type = "commit"; ref_id = sha;
        description =
          String_util.utf8_safe ~max_bytes:120 ~suffix:"..." msg |> String_util.to_string }
    ) commits
  in
  let open_loops =
    match snapshot with
    | None -> []
    | Some s ->
      List.mapi (fun i item ->
        { loop_id = Printf.sprintf "ol-%d" i;
          description = item;
          status = "in_progress";
          blocking_reason = None }
      ) s.next_items
  in
  let decisions =
    match snapshot with
    | None -> []
    | Some s ->
      List.mapi (fun i d ->
        { decision_id = Printf.sprintf "d-%d" i;
          summary = d;
          rationale = "" }
      ) s.decisions
  in
  { since_checkpoint_id = session_id;
    evidence_refs;
    updated_paths = git_changes;
    open_loops;
    decisions;
    keeper_state = snapshot;
    created_at = Unix.gettimeofday ();
  }

(** Render delta entry as a markdown section suitable for
    inclusion in session-state.md or handoff output. *)
let to_markdown (entry : delta_entry) : string =
  let buf = Buffer.create 1024 in
  let add = Buffer.add_string buf in
  add "## Delta Entry\n\n";
  (match entry.since_checkpoint_id with
   | Some id -> add (Printf.sprintf "Base: %s\n\n" id)
   | None -> add "Base: (first session)\n\n");
  if entry.evidence_refs <> [] then begin
    add "### Evidence\n";
    List.iter (fun (r : evidence_ref) ->
      add (Printf.sprintf "- [%s] %s: %s\n" r.ref_type r.ref_id r.description)
    ) entry.evidence_refs;
    add "\n"
  end;
  if entry.updated_paths <> [] then begin
    add "### Changed paths\n";
    List.iter (fun p -> add (Printf.sprintf "- %s\n" p)) entry.updated_paths;
    add "\n"
  end;
  if entry.open_loops <> [] then begin
    add "### Open loops\n";
    List.iter (fun (l : open_loop) ->
      add (Printf.sprintf "- [%s] %s" l.status l.description);
      (match l.blocking_reason with
       | Some r -> add (Printf.sprintf " (blocked: %s)" r)
       | None -> ());
      add "\n"
    ) entry.open_loops;
    add "\n"
  end;
  if entry.decisions <> [] then begin
    add "### Decisions\n";
    List.iter (fun (d : decision) ->
      add (Printf.sprintf "- %s" d.summary);
      if d.rationale <> "" then
        add (Printf.sprintf " — %s" d.rationale);
      add "\n"
    ) entry.decisions;
    add "\n"
  end;
  Buffer.contents buf
