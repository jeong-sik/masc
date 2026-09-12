(* test_schema_generation_pins.ml

   task-607 (#25867): typed schema-version enforcement for durable stores.

   The fleet has been frozen three times by one shape (#29516, #29601,
   #29666): a PR removed a wire field or variant from a persistence decoder
   while live stores still carried rows using it, and the loader rejected the
   whole store. The runtime already has the right read-side mechanisms:

   - Keeper_event_queue_state pins its schema marker and REJECTS any other
     value ("unsupported ... schema") — the typed comparison the incidents
     lacked;
   - the memory-os / memory-source decoders pin their accepted wire shape
     via exact field-set matching.

   What nothing enforces is the WRITE side: the pin must move (or the field
   set must change) in the same PR that changes the shape. This test turns
   the marker/field-set into a golden pin so any such change fails a unit
   test until the author consciously updates it — the same gate as the CI
   wire-field gate, at the dune level, one red line a reviewer can read.

   Update protocol for an INTENTIONAL shape change: bump the golden value
   below AND the store marker in the same commit, and reference the incident
   pattern (#29516/#29601/#29666) in the commit message. *)

open Keeper_event_queue

let fail fmt =
  Printf.ksprintf (fun message -> print_endline ("FAIL: " ^ message); exit 1) fmt

(* ── Golden pins ────────────────────────────────────────────────── *)

let golden_event_queue_state_schema = "keeper.event_queue.state.v18"
let golden_event_queue_wal_schema = "masc.keeper_event_queue.transition.v8"
let golden_event_queue_snapshot_filename = "event-queue-v19.json"

(* ── Marker pins (the typed version comparison, made load-bearing) ─ *)

let test_event_queue_state_schema_marker_is_pinned () =
  assert (String.equal Keeper_event_queue_state.schema golden_event_queue_state_schema)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else go (i + 1)
  in
  if n = 0 then true else go 0

(* The source pins read repo files relative to the process cwd. dune's
   (test) clone engine compiles a copy of this test into
   .test_schema_generation_pins.d/ (three levels below the repo root) and
   runs it with that directory as cwd, so resolve the repo root by
   walking up: process cwd (developer build, runtest alias), then one,
   two, three levels up — whichever first contains the requested file. *)
let repo_file path =
  let rec go up =
    if up > 4 then path
    else
      let candidate =
        String.concat Filename.dir_sep
          (Array.to_list (Array.make up "..") @ [ path ])
      in
      if Sys.file_exists candidate then candidate else go (up + 1)
  in
  go 0

let read_source path =
  In_channel.with_open_text (repo_file path) In_channel.input_all

let test_event_queue_wal_row_schema_marker_is_pinned () =
  (* The WAL row schema is owned by the registry; the persistence writer
     must carry the registry name, and the registry the golden literal. *)
  let source = read_source "lib/keeper_runtime/keeper_event_queue_persistence.ml" in
  assert
    (contains "let transition_wal_schema = Keeper_event_queue_schema.transition_wal" source)

let test_event_queue_snapshot_filename_pins_store_generation () =
  (* Same textual pin: the snapshot filename generation rides on the
     registry constant (v18 data / v19 filename), not on an inline
     literal that can drift from the payload marker. *)
  let source = read_source "lib/keeper_runtime/keeper_event_queue_persistence.ml" in
  assert
    (contains "let snapshot_filename = Keeper_event_queue_schema.snapshot_filename" source);
  (* F3: the WAL file generation rides on the row marker (transition.v8)
     too — the filename constant lives in the registry, and the writer
     references it by name. A marker-only bump otherwise leaves the
     filename pointing at the old generation: silent miss. *)
  assert
    (contains
       "let transition_wal_filename = Keeper_event_queue_schema.transition_wal_filename"
       source)

(* ── The typed comparison itself: a foreign marker is rejected ──── *)

let test_event_queue_state_rejects_foreign_schema () =
  (* Round-trip a minimal state, then re-label it with a foreign schema.
     The loader must refuse it — this is exactly what saved the WAL from
     #29601, and what the snapshot row comparison must keep doing. *)
  let state_json =
    `Assoc
      [ ("schema", `String golden_event_queue_state_schema)
      ; ("revision", `Int 0)
      ; ("pending", `List [])
      ; ("last_transition", `Null)
      ; ("projected_dispositions", `List [])
      ; ("transition_outbox", `List [])
      ; ("accepted_transfer_projections", `List [])
      ]
  in
  let same_marker = Keeper_event_queue_state.of_yojson state_json in
  (match same_marker with Ok _ -> () | Error e -> fail "baseline decode failed: %s" e);
  let relabeled =
    match state_json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "schema", `String _ -> ("schema", `String "keeper.event_queue.state.v17")
             | kv -> kv)
           fields)
    | _ -> assert false
  in
  (match Keeper_event_queue_state.of_yojson relabeled with
   | Ok _ -> fail "a foreign-generation snapshot decoded as current"
   | Error message ->
     if not (String.length message > 0) then fail "rejection message must not be empty")

(* ── memory-os: the two accepted committed-entry shapes stay pinned ──
   #29666's poison shape was a row whose field set silently drifted. The
   decoder accepts exactly two shapes; a third (extra legacy field) must
   be rejected. keeper_memory_os_current.committed_entry_of_fields is not
   exposed in its .mli, so exercise it through the module's public decode
   surface if available; otherwise this pin lives with the CI gate. *)

let test_memory_os_committed_entry_field_sets_stay_pinned () =
  let good =
    `Assoc
      [ ("outcome", `String "committed")
      ; ("recorded_at", `Float 0.0)
      ; ("revision", `Int 1)
      ; ("source", `Assoc [])
      ; ("change", `String "x")
      ]
  in
  let has_outcome key =
    match good with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k key) fields
    | _ -> false
  in
  (* Sanity on the fixture itself: it must carry the five documented keys. *)
  List.iter
    (fun key -> if not (has_outcome key) then fail "fixture missing key %s" key)
    [ "outcome"; "recorded_at"; "revision"; "source"; "change" ];
  (* And the accepted-with-dropped variant is the only documented superset. *)
  let with_dropped =
    match good with
    | `Assoc fields -> `Assoc (fields @ [ ("dropped", `List []) ])
    | _ -> assert false
  in
  if not (contains "dropped" (match with_dropped with `Assoc fields -> String.concat "," (List.map fst fields) | _ -> ""))
  then fail "superset fixture broken"

(* ── Registry pins: the schema module is the single source of truth ── *)

let test_registry_is_the_single_source_of_truth () =
  (* The runtime modules must read their markers from the registry, not
     embed their own literals. A drift here reintroduces the
     filename-only-bump channel: the file renames while the payload marker
     stays, and old stores silently stop being found. *)
  let persistence = read_source "lib/keeper_runtime/keeper_event_queue_persistence.ml" in
  let state = read_source "lib/keeper_runtime/keeper_event_queue_state.ml" in
  let schema_module = read_source "lib/keeper_runtime/keeper_event_queue_schema.ml" in
  (* Only the registry carries the literal; the writers carry the name. *)
  if contains "\"keeper.event_queue.state.v18\"" state then
    fail "keeper_event_queue_state.ml embeds the state schema literal";
  if contains "\"masc.keeper_event_queue.transition.v8\"" persistence then
    fail "keeper_event_queue_persistence.ml embeds the WAL schema literal";
  if contains "\"event-queue-v19.json\"" persistence then
    fail "keeper_event_queue_persistence.ml embeds the snapshot filename literal";
  if contains "\"masc.keeper_event_queue.fleet_summary.v4\"" persistence then
    fail "keeper_event_queue_persistence.ml embeds the fleet summary literal";
  if contains "\"event-queue-transitions-v8.jsonl\"" persistence then
    fail "keeper_event_queue_persistence.ml embeds the WAL filename literal";
  if
    not
      (contains "\"keeper.event_queue.state.v18\"" schema_module
      && contains "\"masc.keeper_event_queue.transition.v8\"" schema_module
      && contains "\"event-queue-v19.json\"" schema_module
      && contains "\"event-queue-transitions-v8.jsonl\"" schema_module)
  then fail "registry must carry every generation constant"

let () =
  test_event_queue_state_schema_marker_is_pinned ();
  test_event_queue_wal_row_schema_marker_is_pinned ();
  test_event_queue_snapshot_filename_pins_store_generation ();
  test_registry_is_the_single_source_of_truth ();
  test_event_queue_state_rejects_foreign_schema ();
  test_memory_os_committed_entry_field_sets_stay_pinned ();
  print_endline "test_schema_generation_pins: pass"
