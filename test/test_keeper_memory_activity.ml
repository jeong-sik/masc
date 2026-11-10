open Alcotest
module Activity = Masc.Keeper_memory_activity
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types

let fact claim = Memory.observed ~claim ~category:Memory.Constraint ~now:10.
    ~origin:{kind = Memory.Authored; trace_id = "pass"}
let old_a = fact "original a"
let old_b = fact "original b"
let successor = fact "combined claim"

let row ?(transition = Some "rewritten") ?(links = []) removed added =
  let snapshot : Current.t =
    { revision = 2; updated_at = 20.; source = {kind = Current.Librarian; trace_id = "pass"}
    ; facts = added; change = {added; removed; retained = 0; invalidated = []} } in
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
  let malformed = `Assoc ["limit", `Int 1; "journal_lines", `Int 0;
    "events", `List [`Assoc ["kind", `String "invented"]]; "notes", `List []] in
  check bool "malformed activity is not an empty success" true
    (Result.is_error (Activity.of_json malformed))

let () = run "Keeper memory activity"
  ["committed lineage",
    [test_case "absorption retains endpoints" `Quick test_absorption;
     test_case "orphan archive is not commit evidence" `Quick test_orphan;
     test_case "unchanged and unmarked observations" `Quick test_unchanged;
     test_case "revision differs from absorption" `Quick test_revision;
     test_case "read model codec" `Quick test_codec]]
