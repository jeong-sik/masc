(** Memory_stream_sync — Batch sync memory_stream JSONL entries to Neo4j.

    Reads high-importance memory entries from an agent's JSONL stream and
    creates corresponding Memory nodes in Neo4j via GraphQL mutations.
    Uses MERGE semantics (idempotent — safe to run multiple times).

    Intended to be called periodically (e.g., at session end, keeper handoff,
    or via MCP tool) rather than on every add_memory call, to avoid coupling
    the hot path to network availability.

    @since 2.121.0 *)

open Printf

(** Minimum importance for a memory entry to be synced to Neo4j.
    Configurable via MASC_MEMORY_SYNC_MIN_IMPORTANCE (default: 7). *)
let memory_type_to_string = function
  | Memory_stream.Observation _ -> "observation"
  | Memory_stream.Action _ -> "action"
  | Memory_stream.Reflection _ -> "reflection"
  | Memory_stream.Plan _ -> "plan"

let min_importance () =
  match Sys.getenv_opt "MASC_MEMORY_SYNC_MIN_IMPORTANCE" with
  | Some s -> (try max 1 (min 10 (int_of_string s)) with Failure _ -> 7)
  | None -> 7

(** Build a Cypher MERGE statement for a batch of memory entries.
    Uses MERGE on id to ensure idempotency. *)
let cypher_merge_batch (entries : Memory_stream.memory_entry list) : string =
  let entry_to_props (e : Memory_stream.memory_entry) =
    sprintf
      "{ id: \"%s\", content: \"%s\", user_id: \"%s\", importance: %d, entry_type: \"%s\", created_at: datetime({epochSeconds: %d}) }"
      (String.escaped e.id)
      (String.escaped (String.sub e.content 0 (min 500 (String.length e.content))))
      (String.escaped e.agent_name)
      e.importance
      (memory_type_to_string e.entry_type)
      (int_of_float e.timestamp)
  in
  let rows = List.map entry_to_props entries in
  sprintf
    "UNWIND [%s] AS row \
     MERGE (m:Memory {id: row.id}) \
     ON CREATE SET m.content = row.content, m.user_id = row.user_id, \
       m.importance = row.importance, m.entry_type = row.entry_type, \
       m.created_at = row.created_at, m.source = 'memory_stream' \
     ON MATCH SET m.importance = row.importance \
     RETURN count(m) AS synced"
    (String.concat ", " rows)

type sync_result = {
  total_entries : int;
  eligible : int;
  synced : int;
  errors : string list;
}

let sync_result_to_json (r : sync_result) : Yojson.Safe.t =
  `Assoc [
    ("total_entries", `Int r.total_entries);
    ("eligible", `Int r.eligible);
    ("synced", `Int r.synced);
    ("errors", `List (List.map (fun e -> `String e) r.errors));
  ]

(** Sync an agent's memory stream to Neo4j.
    Reads all entries, filters by importance >= min_importance,
    and MERGE-creates Memory nodes in batches of [batch_size]. *)
let sync ~agent_name ?(batch_size=20) () : sync_result =
  let all_entries = Memory_stream.load_all_entries ~agent_name in
  let min_imp = min_importance () in
  let eligible = List.filter (fun (e : Memory_stream.memory_entry) ->
    e.importance >= min_imp
  ) all_entries in
  let total = List.length all_entries in
  let eligible_count = List.length eligible in
  if eligible_count = 0 then
    { total_entries = total; eligible = 0; synced = 0; errors = [] }
  else begin
    (* Batch the entries *)
    let rec batch_list acc = function
      | [] -> List.rev acc
      | lst ->
        let take = List.filteri (fun i _ -> i < batch_size) lst in
        let drop = List.filteri (fun i _ -> i >= batch_size) lst in
        batch_list (take :: acc) drop
    in
    let batches = batch_list [] eligible in
    let synced = ref 0 in
    let errors = ref [] in
    List.iter (fun batch ->
      let cypher = cypher_merge_batch batch in
      let mutation = sprintf
        "mutation { executeRaw(statement: \"%s\") }"
        (String.escaped cypher)
      in
      match Graphql_client.mutate ~timeout_sec:15.0 ~mutation () with
      | Ok _data ->
        synced := !synced + List.length batch
      | Error msg ->
        (* GraphQL mutation might not support executeRaw.
           Fall back to simpler per-entry createMemories mutation. *)
        Log.Memory.warn "Batch sync failed (%s), trying individual mutations" msg;
        List.iter (fun (e : Memory_stream.memory_entry) ->
          let m = sprintf
            "mutation { createMemories(input: [{ id: \"%s\", content: \"%s\", userId: \"%s\" }]) { memories { id } } }"
            (String.escaped e.id)
            (String.escaped (String.sub e.content 0 (min 500 (String.length e.content))))
            (String.escaped e.agent_name)
          in
          match Graphql_client.mutate ~timeout_sec:10.0 ~mutation:m () with
          | Ok _ -> incr synced
          | Error e_msg ->
            errors := (sprintf "entry %s: %s" e.id e_msg) :: !errors
        ) batch
    ) batches;
    { total_entries = total; eligible = eligible_count;
      synced = !synced; errors = List.rev !errors }
  end
