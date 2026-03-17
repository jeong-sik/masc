(** Agent Permanence — Stable identity across sessions and generations.

    Problem: Agent UUID is regenerated per session. After restart,
    the agent becomes a different entity. This breaks:
    - Reputation continuity
    - Memory attribution
    - Generational learning

    Solution: SHA256(name + creation_date) produces a stable hash
    that survives restarts. Lifetime metrics accumulate in Neo4j.

    @since 2.90.0 *)

(** Permanent agent identity — survives session boundaries. *)
type permanent_id = {
  stable_hash : string;         (** SHA256(name + creation_date), immutable *)
  display_name : string;
  created_at : float;           (** Unix timestamp of first activation *)
  total_sessions : int;
  total_turns : int;
  total_cost_usd : float;
  current_generation : int;
  model_history : string list;  (** Models used across generations *)
}

(** Generate a stable hash from agent name and creation timestamp.
    This hash is deterministic: same name + date = same hash. *)
let compute_stable_hash ~name ~created_at =
  let input = Printf.sprintf "%s:%f" name created_at in
  Digest.string input |> Digest.to_hex

(** Create a new permanent_id for a first-time agent. *)
let create ~name =
  let now = Time_compat.now () in
  let stable_hash = compute_stable_hash ~name ~created_at:now in
  {
    stable_hash;
    display_name = name;
    created_at = now;
    total_sessions = 1;
    total_turns = 0;
    total_cost_usd = 0.0;
    current_generation = 1;
    model_history = [];
  }

(** Increment session count (called on activation). *)
let new_session pid =
  { pid with total_sessions = pid.total_sessions + 1 }

(** Record turn completion. *)
let record_turn pid ~cost_usd =
  { pid with
    total_turns = pid.total_turns + 1;
    total_cost_usd = pid.total_cost_usd +. cost_usd;
  }

(** Record generation change (succession). *)
let advance_generation pid ~model =
  let history =
    if List.mem model pid.model_history then pid.model_history
    else model :: pid.model_history
  in
  { pid with
    current_generation = pid.current_generation + 1;
    model_history = history;
  }

(** Serialize to JSON for JSONL backup. *)
let to_yojson pid =
  `Assoc [
    ("stable_hash", `String pid.stable_hash);
    ("display_name", `String pid.display_name);
    ("created_at", `Float pid.created_at);
    ("total_sessions", `Int pid.total_sessions);
    ("total_turns", `Int pid.total_turns);
    ("total_cost_usd", `Float pid.total_cost_usd);
    ("current_generation", `Int pid.current_generation);
    ("model_history", `List (List.map (fun m -> `String m) pid.model_history));
  ]

(** Deserialize from JSON. Unknown fields are ignored for forward compat. *)
let of_yojson json =
  let open Yojson.Safe.Util in
  try
    let stable_hash = json |> member "stable_hash" |> to_string in
    let display_name = json |> member "display_name" |> to_string in
    let created_at = json |> member "created_at" |> to_float in
    let total_sessions =
      (try json |> member "total_sessions" |> to_int
       with Type_error _ -> 0)
    in
    let total_turns =
      (try json |> member "total_turns" |> to_int
       with Type_error _ -> 0)
    in
    let total_cost_usd =
      (try json |> member "total_cost_usd" |> to_float
       with Type_error _ -> 0.0)
    in
    let current_generation =
      (try json |> member "current_generation" |> to_int
       with Type_error _ -> 1)
    in
    let model_history =
      (try json |> member "model_history" |> to_list |> List.map to_string
       with Type_error _ -> [])
    in
    Ok {
      stable_hash; display_name; created_at;
      total_sessions; total_turns; total_cost_usd;
      current_generation; model_history;
    }
  with exn ->
    Error (Printf.sprintf "agent_permanence.of_yojson: %s" (Printexc.to_string exn))

(** {1 JSONL Persistence}

    Backup permanent IDs to .masc/permanence/{agent}.jsonl.
    This is defense-in-depth alongside Neo4j. *)

let permanence_dir () =
  let me_root = Env_config.me_root () in
  Filename.concat me_root ".masc/permanence"

let ensure_dir dir =
  if not (Sys.file_exists dir) then
    let rec mkdir_p path =
      let parent = Filename.dirname path in
      if parent <> path && not (Sys.file_exists parent) then
        mkdir_p parent;
      if not (Sys.file_exists path) then
        Unix.mkdir path 0o755
    in
    mkdir_p dir

(** Save permanent_id to JSONL file (append). *)
let save_to_jsonl pid =
  let dir = permanence_dir () in
  ensure_dir dir;
  let file = Filename.concat dir (pid.display_name ^ ".jsonl") in
  Fs_compat.append_jsonl file (to_yojson pid)

(** Load the most recent permanent_id from JSONL file. *)
let load_from_jsonl ~name =
  let dir = permanence_dir () in
  let file = Filename.concat dir (name ^ ".jsonl") in
  if not (Sys.file_exists file) then None
  else
    let content = Fs_compat.load_file file in
    let lines = String.split_on_char '\n' content
      |> List.filter (fun line -> String.length (String.trim line) > 0) in
    match List.rev lines with
    | [] -> None
    | last_line :: _ ->
      match Yojson.Safe.from_string last_line |> of_yojson with
      | Ok pid -> Some pid
      | Error _ -> None

(** {1 Neo4j Integration}

    Stores stable_hash, total_sessions, total_turns on Agent nodes.
    Uses MERGE to create-or-update. *)

(** Escape string for Cypher queries. *)
let escape_cypher s =
  s
  |> String.split_on_char '\''
  |> String.concat "\\'"
  |> String.split_on_char '\n'
  |> String.concat "\\n"

(** Build Cypher query to update permanence fields on Agent node. *)
let build_neo4j_update_query pid =
  Printf.sprintf
    {|MERGE (a:Agent {name: '%s'})
SET a.stable_hash = '%s',
    a.total_sessions = %d,
    a.total_turns = %d,
    a.total_cost_usd = %f,
    a.current_generation = %d,
    a.permanence_updated_at = datetime()
RETURN a.name AS name, a.stable_hash AS stable_hash|}
    (escape_cypher pid.display_name)
    pid.stable_hash
    pid.total_sessions
    pid.total_turns
    pid.total_cost_usd
    pid.current_generation

(** {1 Resolve or Create}

    Entry point: given an agent name, load existing identity or create new. *)

let resolve_or_create ~name =
  match load_from_jsonl ~name with
  | Some pid ->
      let updated = new_session pid in
      save_to_jsonl updated;
      updated
  | None ->
      let pid = create ~name in
      save_to_jsonl pid;
      pid
