open Alcotest
module Activity = Masc.Keeper_memory_activity
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types

let fact claim = Memory.observed ~claim ~category:Memory.Constraint ~now:10.
    ~origin:{kind = Memory.Authored; trace_id = "pass"}
let old_a = fact "original a"
let old_b = fact "original b"
let successor = fact "combined claim"

let snapshot ?(retained = []) removed added : Current.t =
  { revision = 2; updated_at = 20.; source = {kind = Current.Librarian; trace_id = "pass"}
  ; facts = added @ retained;
    change = {added; removed; retained = List.length retained; invalidated = []} }

let row ?(retained = []) ?(transition = Some "rewritten") ?(links = []) removed added =
  let snapshot = snapshot ~retained removed added in
  let stored = Current.to_json snapshot in
  `Assoc
    ([ "outcome", `String "committed"; "recorded_at", `Float 20.; "revision", `Int 2
     ; "source", Yojson.Safe.Util.member "source" stored
     ; "change", Yojson.Safe.Util.member "change" stored
     ; "revision_links", `List (List.map (fun (a,b) -> `Assoc
         ["superseded", `String (Memory.memory_id a);
          "superseded_by", `String (Memory.memory_id b)]) links) ]
     @ match transition with None -> [] | Some token -> ["commit_effect", `String token])

let archive ?(trace = "pass") ?(at = 20.) original : Masc.Keeper_memory_absorbed.record =
  { recorded_at = at; trace_id = trace; memory_id = Memory.memory_id original
  ; into = Memory.memory_id successor; fact = original }
let project absorbed json = match Activity.project ~identity:"journal:42" ~absorbed json with
  | Ok events -> events | Error reason -> fail reason
let has_absorption events = List.exists (fun (event : Activity.event) ->
  event.kind = Activity.Absorbed) events

let test_absorption () =
  let events = project [archive old_a; archive old_b]
      (row [old_a; old_b] [successor]) in
  check int "one committed formation, no duplicate deletion" 1 (List.length events);
  let event = List.hd events in
  check bool "absorption" true (event.kind = Activity.Absorbed);
  check (list string) "exact originals" [Memory.memory_id old_a; Memory.memory_id old_b]
    (List.map (fun (fact : Activity.fact) -> fact.memory_id) event.before);
  check (list string) "exact successor" [Memory.memory_id successor]
    (List.map (fun (fact : Activity.fact) -> fact.memory_id) event.after)

let test_orphan () =
  check bool "prepublication append alone proves no absorption" false
    (has_absorption (project [archive old_a] (row [] [successor])));
  List.iter (fun record ->
    check bool "different pass cannot supply lineage" false
      (has_absorption (project [record] (row [old_a] [successor]))))
    [archive ~trace:"uncommitted" old_a; archive ~at:19. old_a]

let test_unchanged () =
  check int "unchanged observation repeats no previous change" 0
    (List.length (project [archive old_a]
       (row ~transition:(Some "unchanged") [old_a] [successor])));
  check bool "unmarked legacy transition stays unknown" true
    (Result.is_error (Activity.project ~identity:"journal:42" ~absorbed:[]
       (row ~transition:None [old_a] [successor])))

let test_revision () =
  let events = project [] (row ~links:[old_a,successor] [old_a] [successor]) in
  check int "one revision" 1 (List.length events);
  check bool "revision is not absorption" true ((List.hd events).kind = Activity.Revised)

let test_codec () =
  let activity : Activity.t =
    {limit = 50; journal_lines = 1;
     events = project [archive old_a] (row [old_a] [successor]); notes = ["partial archive"]} in
  (match Activity.of_json (Activity.to_json activity) with
   | Error reason -> fail reason
   | Ok decoded ->
     check bool "identities, contents, lineage and notes round trip" true (decoded = activity));
  let change_event field value = match Activity.to_json activity with
    | `Assoc fields -> `Assoc (List.map (fun (key, content) -> if key <> "events" then key, content else
      key, (match content with `List (`Assoc event :: rest) ->
        `List (`Assoc ((field, value) :: List.remove_assoc field event) :: rest)
        | _ -> fail "activity fixture has no event")) fields)
    | _ -> fail "activity fixture is not an object" in
  check bool "unknown kind does not become an empty success" true
    (Result.is_error (Activity.of_json (change_event "kind" (`String "invented"))));
  let forged = `List [`Assoc ["memory_id", `String (Memory.memory_id old_a);
    "claim", `String "different bytes"]] in
  check bool "claim must match its exact identity" true
    (Result.is_error (Activity.of_json (change_event "before" forged)))

let test_split () =
  let events = project [] (row ~links:[old_a,old_b; old_a,successor] [old_a] [old_b; successor]) in
  check int "both split successors survive" 2 (List.length events);
  let ids = List.map (fun (event : Activity.event) -> event.identity) events in
  check int "split edges have distinct identities" 2 (List.length (List.sort_uniq String.compare ids))

let test_retained () =
  let json = row ~retained:[successor] [old_a] [] in
  let observed = snapshot ~retained:[successor] [old_a] [] in
  let require = function Ok events -> events | Error reason -> fail reason in
  let events = Activity.project ~snapshot:observed ~identity:"journal:42" ~absorbed:[archive old_a] json |> require in
  check int "retained target creates only one formation event" 1 (List.length events);
  check bool "matching guarded snapshot resolves absorption" true (has_absorption events);
  let unknown = project [archive old_a] json in
  check bool "historical retained successor stays unresolved" true
    (List.exists (fun (event : Activity.event) -> event.kind = Activity.Relation_unavailable) unknown);
  check bool "unresolved successor is not a confirmed claim" true
    (List.exists (fun (event : Activity.event) ->
       List.exists (fun (fact : Activity.fact) -> fact.memory_id = Memory.memory_id successor && fact.claim = None)
         event.after) unknown);
  let wrong = {observed with source = {observed.source with trace_id = "different pass"}} in
  check bool "same revision alone cannot resolve lineage" false
    (has_absorption (Activity.project ~snapshot:wrong ~identity:"journal:42" ~absorbed:[archive old_a] json |> require));
  let revisions = Activity.project ~snapshot:observed ~identity:"journal:42" ~absorbed:[]
      (row ~retained:[successor] ~links:[old_a,successor] [old_a] []) |> require in
  check bool "retained revision is a revision" true
    (List.exists (fun (event : Activity.event) -> event.kind = Activity.Revised) revisions)

let test_bad_clock () =
  List.iter (fun clock -> match row [old_a] [successor] with
    | `Assoc fields ->
      check bool "invalid clock refuses only this journal row" true
        (Result.is_error (Activity.project ~identity:"journal:42" ~absorbed:[]
          (`Assoc (("recorded_at", `Float clock) :: List.remove_assoc "recorded_at" fields))))
    | _ -> fail "journal fixture is not an object") [-1.; Float.nan; Float.infinity]

let test_partial_archive () =
  match Activity.project ~archive_error:"archive unreadable" ~identity:"journal:42" ~absorbed:[]
      (row [old_a] [successor]) with
  | Error reason -> fail reason
  | Ok events ->
    check bool "unreadable archive does not assert generic removal" false
      (List.exists (fun (event : Activity.event) -> event.kind = Activity.Removed) events);
    check bool "lineage uncertainty remains visible" true
      (List.exists (fun (event : Activity.event) -> event.kind = Activity.Relation_unavailable) events)

let test_reobservation () =
  let next = {old_a with last_seen = 11.} in
  let json = row [old_a] [next] in
  let require = function Ok value -> value | Error reason -> fail reason in
  let events = Activity.project ~archive_error:"archive unreadable" ~identity:"journal:42"
      ~absorbed:[] json |> require in
  check int "payload update is one event" 1 (List.length events);
  check bool "payload update is not retirement" true ((List.hd events).kind = Activity.Reobserved);
  let keepers_dir = Filename.temp_file "memory-activity-" ".dir" in
  Sys.remove keepers_dir;
  Unix.mkdir keepers_dir 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree keepers_dir) (fun () ->
    Fs_compat.save_file_atomic
      (Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha")
      (Yojson.Safe.to_string json ^ "\n") |> require;
    Fs_compat.save_file_atomic
      (Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha")
      "not JSON\n" |> require;
    let observed = Activity.read ~keepers_dir ~keeper_id:"alpha" ~limit:50 in
    check (list string) "payload update does not read unrelated broken archive" [] observed.notes;
    check int "read retains one actual reobservation" 1 (List.length observed.events))

let () = run "Keeper memory activity"
  ["committed lineage",
    [test_case "absorption retains endpoints" `Quick test_absorption;
     test_case "orphan archive is not commit evidence" `Quick test_orphan;
     test_case "unchanged and unmarked observations" `Quick test_unchanged;
     test_case "revision differs from absorption" `Quick test_revision;
     test_case "read model codec" `Quick test_codec;
     test_case "split edge identities" `Quick test_split;
     test_case "retained successor evidence" `Quick test_retained;
     test_case "bad observation clock" `Quick test_bad_clock;
     test_case "partial archive" `Quick test_partial_archive;
     test_case "reobservation is not retirement" `Quick test_reobservation]]
