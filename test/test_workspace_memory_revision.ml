module Ledger = Masc.Workspace_memory_ledger
module Briefing = Masc.Workspace_memory_briefing
module Revision = Masc.Workspace_memory_revision

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let written = function Ok value -> value | Error error -> Alcotest.fail (Revision.error_to_string error)
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let str value = `String value
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let rec remove path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_base f =
  let base_path = Filename.temp_dir "workspace-memory-revision" "" in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> f base_path)

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)

(* A ledger with one claim the writer's fact joined. *)
let ledger_json =
  `Assoc
    [ "schema", str "workspace.memory.ledger.v1"
    ; "claims", `List [`Assoc ["claim_id", str "c1"; "claim", str "PDF has ten pages"]]
    ; "conflicts", `List []
    ; "facts", `List
        [ `Assoc
            [ "keeper_id", str "writer"; "store", str "ordinary"
            ; "claim_sha256", str (sha "PDF has ten pages")
            ; "disposition", `Assoc ["kind", str "claim"; "claim_id", str "c1"] ] ] ]
let ledger = get (Ledger.of_json ledger_json)

(* The same ledger in another key order: it decodes to [ledger], but these are
   not the bytes its revision names. *)
let reordered = match ledger_json with
  | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.rev fields))
  | _ -> Alcotest.fail "ledger fixture"

let briefing =
  let contract = Briefing.contract ~template:"revision-fixture" in
  let sources = [ ({ id = "a"; kind = Briefing.Claim; text = "The report is complete" } : Briefing.source) ] in
  let render input = Ok ("Summarize:\n" ^ Yojson.Safe.to_string input) in
  match get (Briefing.prepare ~sources ~contract ~render Briefing.empty) with
  | Briefing.Prepared batch -> get (Briefing.accept batch ~text:"The report is complete.")
  | Briefing.Unchanged | Briefing.Cleanup _ -> Alcotest.fail "expected a Briefing batch"

let ledger_revision base_path = written (Revision.write_ledger ~base_path ledger)

let named_ledger digest = match get (Revision.of_json (`Assoc ["kind", str "ledger"; "sha256", str digest])) with
  | Revision.Ledger revision -> revision
  | Revision.Briefing _ -> Alcotest.fail "expected a ledger revision"

let refused_as name expected = function
  | Ok _ -> Alcotest.failf "%s: accepted" name
  | Error error ->
    if not (expected error) then Alcotest.failf "%s: %s" name (Revision.error_to_string error)

let damaged = function Revision.Damaged _ -> true
  | Revision.Missing _ | Revision.Unavailable _ | Revision.Unencodable _ -> false

let test_ledger_revision_is_the_bytes_save_writes () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  Alcotest.(check string) "the revision is the ledger digest every reader already uses"
    (Ledger.sha256 ledger) (Revision.ledger_sha256 revision);
  Alcotest.(check string) "and the revision computed without writing"
    (Revision.ledger_sha256 (Revision.of_ledger ledger)) (Revision.ledger_sha256 revision);
  get (Ledger.save ~base_path ledger);
  let file = read_file (Revision.path ~base_path (Revision.Ledger revision)) in
  Alcotest.(check string) "the revision file holds the bytes ledger.json holds"
    (read_file (Filename.concat (Ledger.directory ~base_path) "ledger.json")) file;
  Alcotest.(check string) "its SHA-256 is its name" (Revision.ledger_sha256 revision) (sha file))

let test_one_state_is_one_file () = with_base (fun base_path ->
  let first = ledger_revision base_path in
  let again = ledger_revision base_path in
  Alcotest.(check string) "the same state has the same revision"
    (Revision.ledger_sha256 first) (Revision.ledger_sha256 again);
  let directory = Filename.dirname (Revision.path ~base_path (Revision.Ledger first)) in
  Alcotest.(check (list string)) "and the store holds one file for it"
    [Revision.ledger_sha256 first ^ ".json"] (Array.to_list (Sys.readdir directory)))

let test_states_read_back () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  Alcotest.check json "the ledger reads back as written"
    (Ledger.to_json ledger) (Ledger.to_json (written (Revision.read_ledger ~base_path revision)));
  let revision = written (Revision.write_briefing ~base_path briefing) in
  Alcotest.check json "the Briefing state reads back as written"
    (Briefing.to_json briefing) (Briefing.to_json (written (Revision.read_briefing ~base_path revision))))

let test_briefing_revision_is_key_sorted_not_the_published_file () = with_base (fun base_path ->
  let revision = written (Revision.write_briefing ~base_path briefing) in
  Alcotest.(check string) "the revision computed without writing"
    (Revision.briefing_sha256 (get (Revision.of_briefing briefing))) (Revision.briefing_sha256 revision);
  let file = read_file (Revision.path ~base_path (Revision.Briefing revision)) in
  Alcotest.(check string) "the file is the key-sorted state" (Revision.briefing_sha256 revision) (sha file);
  let directory = Ledger.directory ~base_path in
  get (Briefing.save ~directory briefing);
  let published = read_file (Briefing.path ~directory) in
  Alcotest.(check bool) "briefing.json keeps its own key order, so its hash is not the revision" false
    (String.equal (sha published) (Revision.briefing_sha256 revision));
  Alcotest.check json "yet both hold the same state"
    (Briefing.to_json briefing) (Briefing.to_json (get (Briefing.of_json (Yojson.Safe.from_string published)))))

let test_missing_file_is_not_an_empty_state () = with_base (fun base_path ->
  let revision = Revision.of_ledger Ledger.empty in
  refused_as "a revision never written" (function Revision.Missing _ -> true
    | Revision.Damaged _ | Revision.Unavailable _ | Revision.Unencodable _ -> false)
    (Revision.read_ledger ~base_path revision))

let test_damaged_files_are_refused_until_written_again () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  let path = Revision.path ~base_path (Revision.Ledger revision) in
  write_file path (Yojson.Safe.to_string (Ledger.to_json Ledger.empty));
  refused_as "bytes of another state" damaged (Revision.read_ledger ~base_path revision);
  write_file path reordered;
  refused_as "the same state in other bytes" damaged (Revision.read_ledger ~base_path revision);
  ignore (ledger_revision base_path);
  Alcotest.check json "writing the same state again replaces the damaged file"
    (Ledger.to_json ledger) (Ledger.to_json (written (Revision.read_ledger ~base_path revision))))

let test_a_file_must_decode_as_its_kind_and_revision () = with_base (fun base_path ->
  let place bytes =
    let revision = named_ledger (sha bytes) in
    let path = Revision.path ~base_path (Revision.Ledger revision) in
    mkdir_p (Filename.dirname path);
    write_file path bytes;
    revision in
  let briefing_bytes = Yojson.Safe.to_string (Briefing.to_json briefing) in
  refused_as "a Briefing state named as a ledger revision" damaged
    (Revision.read_ledger ~base_path (place briefing_bytes));
  (* Named by the digest of its own bytes, so only the decoded state's revision
     tells it apart. *)
  refused_as "a ledger that is not in the bytes its revision names" damaged
    (Revision.read_ledger ~base_path (place reordered)))

let test_revision_json () =
  let digest = sha "state" in
  List.iter (fun revision ->
    Alcotest.check json "round trip" (Revision.to_json revision)
      (Revision.to_json (get (Revision.of_json (Revision.to_json revision)))))
    [ get (Revision.of_json (`Assoc ["kind", str "ledger"; "sha256", str digest]))
    ; get (Revision.of_json (`Assoc ["sha256", str digest; "kind", str "briefing"])) ];
  List.iter (fun (name, input) -> match Revision.of_json input with
    | Ok _ -> Alcotest.failf "%s: accepted" name
    | Error _ -> ())
    [ "another kind", `Assoc ["kind", str "classification"; "sha256", str digest]
    ; "uppercase digest", `Assoc ["kind", str "ledger"; "sha256", str (String.uppercase_ascii digest)]
    ; "short digest", `Assoc ["kind", str "ledger"; "sha256", str (String.sub digest 0 63)]
    ; "a path for a digest", `Assoc ["kind", str "ledger"; "sha256", str "../../ledger"]
    ; "missing kind", `Assoc ["sha256", str digest]
    ; "another field", `Assoc ["kind", str "ledger"; "sha256", str digest; "state", `Null]
    ; "repeated field", `Assoc ["kind", str "ledger"; "kind", str "ledger"; "sha256", str digest]
    ; "not an object", str digest ]

let test_write_needs_an_existing_workspace () = with_base (fun parent ->
  let base_path = Filename.concat parent "absent" in
  refused_as "a base path that does not exist" (function Revision.Unavailable _ -> true
    | Revision.Missing _ | Revision.Damaged _ | Revision.Unencodable _ -> false)
    (Revision.write_ledger ~base_path ledger);
  Alcotest.(check bool) "and nothing was created" false (Sys.file_exists base_path))

let () =
  Alcotest.run "workspace_memory_revision"
    [ ( "store"
      , [ Alcotest.test_case "a ledger revision is the bytes save writes" `Quick
            test_ledger_revision_is_the_bytes_save_writes
        ; Alcotest.test_case "one state is one file" `Quick test_one_state_is_one_file
        ; Alcotest.test_case "states read back" `Quick test_states_read_back
        ; Alcotest.test_case "a Briefing revision is key-sorted, not the published file" `Quick
            test_briefing_revision_is_key_sorted_not_the_published_file
        ; Alcotest.test_case "a missing file is not an empty state" `Quick
            test_missing_file_is_not_an_empty_state
        ; Alcotest.test_case "damaged files are refused until written again" `Quick
            test_damaged_files_are_refused_until_written_again
        ; Alcotest.test_case "a file must decode as its kind and revision" `Quick
            test_a_file_must_decode_as_its_kind_and_revision
        ; Alcotest.test_case "writing needs an existing workspace" `Quick
            test_write_needs_an_existing_workspace ] )
    ; ("codec", [ Alcotest.test_case "revision references" `Quick test_revision_json ]) ]
