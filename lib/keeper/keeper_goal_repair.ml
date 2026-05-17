(** Keeper_goal_repair — Detect and repair empty active_goal_ids.

    When a keeper's [active_goal_ids] is empty, the task filter accepts ALL
    tasks equally, causing claim/release loops. This module:
    1. Detects keepers with empty [active_goal_ids].
    2. Creates a goal from the keeper's [goal] field (purpose statement).
    3. Assigns the new goal ID to [active_goal_ids].

    @since 2.237.0 *)

type repair_source = [ `Created | `Reused ]

let repair_source_to_string = function
  | `Created -> "created"
  | `Reused -> "reused"

type repair_action = {
  keeper_name : string;
  goal_id : string;
  goal_title : string;
  source : repair_source;
}

type repair_result = {
  actions : repair_action list;
  skipped : (string * string) list;  (** (name, reason) *)
  errors : (string * string) list;   (** (name, error) *)
}

let empty_result = { actions = []; skipped = []; errors = [] }

let repair_result_to_yojson r =
  let created = List.filter (fun a -> a.source = `Created) r.actions in
  let reused  = List.filter (fun a -> a.source = `Reused)  r.actions in
  `Assoc [
    ("repaired", `Int (List.length r.actions));
    ("created", `Int (List.length created));
    ("reused", `Int (List.length reused));
    ("skipped", `Int (List.length r.skipped));
    ("errors", `Int (List.length r.errors));
    ("actions", `List (List.map (fun a ->
      `Assoc [
        ("keeper_name", `String a.keeper_name);
        ("goal_id", `String a.goal_id);
        ("goal_title", `String a.goal_title);
        ("source", `String (repair_source_to_string a.source));
      ]) r.actions));
    ("skipped_details", `List (List.map (fun (n, reason) ->
      `Assoc [("name", `String n); ("reason", `String reason)]) r.skipped));
    ("error_details", `List (List.map (fun (n, err) ->
      `Assoc [("name", `String n); ("error", `String err)]) r.errors));
  ]

(** Locate an existing non-terminal goal with the same auto-derived title.
    Reuse path for repeated repairs of the same keeper purpose statement —
    without this, every repair turn creates a fresh goal id even when the
    purpose has not changed (auto-goal accretion, observed live 2026-05-17:
    3 identical verifier goals across 10 days in Goal Store). *)
let find_existing_auto_goal (config : Coord.config) ~(title : string)
    : Goal_store.goal option =
  let st = Goal_store.read_state config in
  List.find_opt (fun (g : Goal_store.goal) ->
    g.title = title
    && (match g.phase with
        | Goal_phase.Dropped | Goal_phase.Completed -> false
        | _ -> true))
    st.goals

(** Derive a goal title from the keeper's purpose statement.
    Truncates to 120 chars and appends "(auto)" to mark it as generated. *)
let goal_title_of_purpose (purpose : string) : string =
  let base = String.trim purpose in
  if base = "" then "(unnamed keeper)"
  else if String.length base > 115 then
    String.sub base 0 115 ^ "… (auto)"
  else
    base ^ " (auto)"

(** Scan all keeper metas and return names with empty active_goal_ids. *)
let find_empty_goal_keepers (config : Coord.config) : string list =
  let keeper_dir =
    Filename.concat (Coord.masc_dir config) "keepers"
  in
  if not (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir) then []
  else begin
    let entries = Sys.readdir keeper_dir in
    Array.fold_left (fun acc entry ->
      if Filename.check_suffix entry ".json" then begin
        let name = Filename.chop_suffix entry ".json" in
        match Keeper_types.read_meta config name with
        | Ok (Some meta) when meta.active_goal_ids = [] ->
            name :: acc
        | _ -> acc
      end else acc
    ) [] entries
    |> List.rev
  end

(** Repair a single keeper: either reuse an existing auto-goal with the
    same derived title, or create a new one. Then assign to the keeper's
    [active_goal_ids]. Returns [Ok action] on success, [Error msg] on
    failure. *)
let repair_keeper (config : Coord.config) (name : string) : (repair_action, string) result =
  match Keeper_types.read_meta config name with
  | Error e -> Error (Printf.sprintf "read_meta failed: %s" e)
  | Ok None -> Error "keeper meta not found"
  | Ok (Some meta) ->
    (* Skip if already has goals *)
    if meta.active_goal_ids <> [] then
      Error "already has active_goal_ids"
    else begin
      let title = goal_title_of_purpose meta.goal in
      let assign_goal ~goal_id ~source =
        let updated = { meta with active_goal_ids = [ goal_id ] } in
        match Keeper_types.write_meta config updated with
        | Error e ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_write_meta_failures
              ~labels:[("keeper", name); ("phase", "goal_repair")]
              ();
            Error (Printf.sprintf "write_meta failed: %s" e)
        | Ok () ->
            Ok { keeper_name = name; goal_id; goal_title = title; source }
      in
      match find_existing_auto_goal config ~title with
      | Some existing ->
          assign_goal ~goal_id:existing.Goal_store.id ~source:`Reused
      | None ->
          (match Goal_store.upsert_goal config ~title () with
           | Error e ->
               Error (Printf.sprintf "goal creation failed: %s" e)
           | Ok (goal, `created) ->
               assign_goal ~goal_id:goal.Goal_store.id ~source:`Created
           | Ok (_, `updated) ->
               Error "unexpected update on new goal")
    end

(** Dry-run: returns what would be repaired without making changes. The
    [source] field on each action records whether the live repair would
    [`Reused] an existing auto-goal or [`Created] a new one. *)
let dry_run (config : Coord.config) : repair_result =
  let names = find_empty_goal_keepers config in
  List.fold_left (fun acc name ->
    match Keeper_types.read_meta config name with
    | Error e -> { acc with errors = (name, e) :: acc.errors }
    | Ok None -> { acc with skipped = (name, "meta not found") :: acc.skipped }
    | Ok (Some meta) ->
        let title = goal_title_of_purpose meta.goal in
        let source =
          match find_existing_auto_goal config ~title with
          | Some _ -> `Reused
          | None -> `Created
        in
        let goal_id =
          match source with
          | `Reused -> "(dry-run-reuse)"
          | `Created -> "(dry-run-create)"
        in
        { acc with actions = { keeper_name = name; goal_id; goal_title = title; source } :: acc.actions }
  ) empty_result names
  |> fun r -> { actions = List.rev r.actions; skipped = List.rev r.skipped; errors = List.rev r.errors }

(** Execute repairs: create goals and assign to keepers. *)
let run (config : Coord.config) : repair_result =
  let names = find_empty_goal_keepers config in
  List.fold_left (fun acc name ->
    match repair_keeper config name with
    | Ok action -> { acc with actions = action :: acc.actions }
    | Error e ->
        if String.starts_with e ~prefix:"already has active_" then
          { acc with skipped = (name, e) :: acc.skipped }
        else
          { acc with errors = (name, e) :: acc.errors }
  ) empty_result names
  |> fun r -> { actions = List.rev r.actions; skipped = List.rev r.skipped; errors = List.rev r.errors }
