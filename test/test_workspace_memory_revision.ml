module Ledger = Masc.Workspace_memory_ledger
module Briefing = Masc.Workspace_memory_briefing
module Revision = Masc.Workspace_memory_revision

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let written = function Ok value -> value | Error error -> Alcotest.fail (Revision.write_error_to_string error)
let read_back = function Ok value -> value | Error error -> Alcotest.fail (Revision.read_error_to_string error)
let sha bytes = Agent_core_sha256.(digest_string bytes |> to_hex)
let str value = `String value
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

(* lstat, so a symbolic link is removed rather than followed. *)
let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path

let with_base f =
  let base_path = Filename.temp_dir "workspace-memory-revision" "" in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> f base_path)

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
let inode path = (Unix.lstat path).Unix.st_ino

(* The store layout, spelled out so that moving it fails here. *)
let revisions base_path = List.fold_left Filename.concat base_path [".masc"; "workspace-memory"; "revisions"]
let revision_file base_path kind digest =
  List.fold_left Filename.concat (revisions base_path) [kind; digest ^ ".json"]
let ledger_file base_path revision = revision_file base_path "ledger" (Revision.ledger_sha256 revision)
let briefing_file base_path revision = revision_file base_path "briefing" (Revision.briefing_sha256 revision)

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

let batch =
  let contract = Briefing.contract ~template:"revision-fixture" in
  let sources = [ ({ id = "a"; kind = Briefing.Claim; text = "The report is complete" } : Briefing.source) ] in
  let render input = Ok ("Summarize:\n" ^ Yojson.Safe.to_string input) in
  match get (Briefing.prepare ~sources ~contract ~render Briefing.empty) with
  | Briefing.Prepared batch -> batch
  | Briefing.Unchanged | Briefing.Cleanup _ -> Alcotest.fail "expected a Briefing batch"

(* The Briefing state while the batch is built, and the state it publishes. *)
let building = Briefing.prepared_state batch
let briefing = get (Briefing.accept batch ~text:"The report is complete.")

let ledger_revision base_path =
  Revision.stored_ledger_revision (written (Revision.write_ledger ~base_path ledger))

let named kind digest = get (Revision.of_json (`Assoc ["kind", str kind; "sha256", str digest]))
let named_ledger digest = match named "ledger" digest with
  | Revision.Ledger revision -> revision
  | Revision.Briefing _ -> Alcotest.fail "expected a ledger revision"
let named_briefing digest = match named "briefing" digest with
  | Revision.Briefing revision -> revision
  | Revision.Ledger _ -> Alcotest.fail "expected a Briefing revision"

(* Puts bytes in the store under the digest of those bytes. *)
let place base_path kind bytes =
  let digest = sha bytes in
  let path = revision_file base_path kind digest in
  mkdir_p (Filename.dirname path);
  write_file path bytes;
  digest

let refused_as name expected = function
  | Ok _ -> Alcotest.failf "%s: accepted" name
  | Error error ->
    if not (expected error) then Alcotest.failf "%s: %s" name (Revision.read_error_to_string error)

let missing = function Revision.Missing _ -> true | Revision.Damaged _ | Revision.Unreadable _ -> false
let damaged = function Revision.Damaged _ -> true | Revision.Missing _ | Revision.Unreadable _ -> false
let unreadable = function Revision.Unreadable _ -> true | Revision.Missing _ | Revision.Damaged _ -> false

let not_written name = function
  | Ok _ -> Alcotest.failf "%s: written" name
  | Error (_ : Revision.write_error) -> ()

let test_ledger_revision_is_the_bytes_save_writes () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  Alcotest.(check string) "the revision is the ledger digest every reader already uses"
    (Ledger.sha256 ledger) (Revision.ledger_sha256 revision);
  Alcotest.(check string) "and the revision computed without writing"
    (Revision.ledger_sha256 (Revision.of_ledger ledger)) (Revision.ledger_sha256 revision);
  get (Ledger.save ~base_path ledger);
  let file = read_file (ledger_file base_path revision) in
  Alcotest.(check string) "the revision file holds the bytes ledger.json holds"
    (read_file (Filename.concat (Ledger.directory ~base_path) "ledger.json")) file;
  Alcotest.(check string) "its SHA-256 is its name" (Revision.ledger_sha256 revision) (sha file))

let test_write_receipt_binds_the_physical_workspace () = with_base (fun base_path ->
  let stored = written (Revision.write_ledger ~base_path ledger) in
  let path, device, inode = Revision.stored_ledger_workspace stored in
  let stat = Unix.stat base_path in
  Alcotest.(check string) "receipt uses the canonical observed workspace" (Unix.realpath base_path) path;
  Alcotest.(check int) "receipt binds its device" stat.Unix.st_dev device;
  Alcotest.(check int) "receipt binds its directory inode" stat.Unix.st_ino inode;
  Alcotest.check json "the receipt names a file already readable in that workspace"
    (Ledger.to_json ledger)
    (Ledger.to_json (read_back (Revision.read_ledger ~base_path (Revision.stored_ledger_revision stored)))))

let test_one_state_is_one_file_written_every_time () = with_base (fun base_path ->
  let first = ledger_revision base_path in
  let file = ledger_file base_path first in
  let before = inode file in
  let again = ledger_revision base_path in
  Alcotest.(check string) "the same state has the same revision"
    (Revision.ledger_sha256 first) (Revision.ledger_sha256 again);
  Alcotest.(check bool) "writing it again replaces the file" true (inode file <> before);
  Alcotest.(check (list string)) "and the store holds one file for it"
    [Revision.ledger_sha256 first ^ ".json"] (Array.to_list (Sys.readdir (Filename.dirname file))))

let test_states_read_back () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  Alcotest.check json "the ledger reads back as written"
    (Ledger.to_json ledger) (Ledger.to_json (read_back (Revision.read_ledger ~base_path revision)));
  (match Briefing.to_json building with
   | `Assoc fields when not (Yojson.Safe.equal `Null (List.assoc "building" fields)) -> ()
   | _ -> Alcotest.fail "the fixture holds a batch being built");
  List.iter (fun (name, state) ->
    let revision = written (Revision.write_briefing ~base_path state) in
    Alcotest.check json (name ^ " reads back as written")
      (Briefing.to_json state) (Briefing.to_json (read_back (Revision.read_briefing ~base_path revision))))
    ["a Briefing state being built", building; "a published Briefing state", briefing])

let test_briefing_revision_is_key_sorted_not_the_published_file () = with_base (fun base_path ->
  let revision = written (Revision.write_briefing ~base_path briefing) in
  Alcotest.(check string) "the revision computed without writing"
    (Revision.briefing_sha256 (Revision.of_briefing briefing)) (Revision.briefing_sha256 revision);
  let file = read_file (briefing_file base_path revision) in
  Alcotest.(check string) "its SHA-256 is its name" (Revision.briefing_sha256 revision) (sha file);
  let directory = Ledger.directory ~base_path in
  get (Briefing.save ~directory briefing);
  let published = read_file (Briefing.path ~directory) in
  Alcotest.(check bool) "briefing.json keeps its own key order, so its hash is not the revision" false
    (String.equal (sha published) (Revision.briefing_sha256 revision));
  Alcotest.check json "yet both hold the same state"
    (Briefing.to_json briefing) (Briefing.to_json (get (Briefing.of_json (Yojson.Safe.from_string published)))))

(* A revision is the name of these bytes, so changing them renames every
   stored Briefing state. *)
let test_briefing_bytes_are_compact_with_sorted_keys () = with_base (fun base_path ->
  let empty = written (Revision.write_briefing ~base_path Briefing.empty) in
  Alcotest.(check string) "the empty state"
    {|{"building":null,"published":null,"schema":"workspace.memory.briefing.v1"}|}
    (read_file (briefing_file base_path empty));
  List.iter (fun (name, state) ->
    let bytes = read_file (briefing_file base_path (written (Revision.write_briefing ~base_path state))) in
    Alcotest.(check string) (name ^ " is compact with every object's keys sorted")
      (Yojson.Safe.to_string (Yojson.Safe.sort (Yojson.Safe.from_string bytes))) bytes)
    ["a state being built", building; "a published state", briefing])

let test_missing_file_is_not_an_empty_state () = with_base (fun base_path ->
  refused_as "a ledger revision never written" missing
    (Revision.read_ledger ~base_path (Revision.of_ledger Ledger.empty));
  refused_as "a Briefing revision never written" missing
    (Revision.read_briefing ~base_path (Revision.of_briefing Briefing.empty)))

let test_damaged_files_are_refused_until_written_again () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  let path = ledger_file base_path revision in
  write_file path (Yojson.Safe.to_string (Ledger.to_json Ledger.empty));
  refused_as "bytes of another state" damaged (Revision.read_ledger ~base_path revision);
  write_file path reordered;
  refused_as "the same state in other bytes" damaged (Revision.read_ledger ~base_path revision);
  ignore (ledger_revision base_path);
  Alcotest.check json "writing the same state again replaces the damaged file"
    (Ledger.to_json ledger) (Ledger.to_json (read_back (Revision.read_ledger ~base_path revision))))

let test_a_file_must_decode_as_its_kind_and_revision () = with_base (fun base_path ->
  let as_ledger bytes = named_ledger (place base_path "ledger" bytes) in
  let as_briefing bytes = named_briefing (place base_path "briefing" bytes) in
  refused_as "bytes that are not JSON" damaged (Revision.read_ledger ~base_path (as_ledger "not json"));
  refused_as "a Briefing state named as a ledger revision" damaged
    (Revision.read_ledger ~base_path (as_ledger (Yojson.Safe.to_string (Briefing.to_json briefing))));
  refused_as "a ledger named as a Briefing revision" damaged
    (Revision.read_briefing ~base_path (as_briefing (Yojson.Safe.to_string (Ledger.to_json ledger))));
  (* Named by the digest of their own bytes, so only the decoded state's
     revision tells these apart. *)
  refused_as "a ledger that is not in the bytes its revision names" damaged
    (Revision.read_ledger ~base_path (as_ledger reordered));
  refused_as "a Briefing state with unsorted keys" damaged
    (Revision.read_briefing ~base_path (as_briefing (Yojson.Safe.to_string (Briefing.to_json briefing)))))

let test_something_other_than_a_file_is_unreadable () = with_base (fun base_path ->
  let revision = Revision.of_ledger ledger in
  let path = ledger_file base_path revision in
  mkdir_p path;
  refused_as "a directory where the file belongs" unreadable (Revision.read_ledger ~base_path revision);
  Unix.rmdir path;
  with_base (fun elsewhere ->
    let target = Filename.concat elsewhere "ledger.json" in
    write_file target (Yojson.Safe.to_string (Ledger.to_json ledger));
    Unix.symlink target path;
    refused_as "a symbolic link to the right bytes" unreadable (Revision.read_ledger ~base_path revision)))

let test_write_needs_a_workspace_directory () = with_base (fun parent ->
  let absent = Filename.concat parent "absent" in
  not_written "a base path that does not exist" (Revision.write_ledger ~base_path:absent ledger);
  Alcotest.(check bool) "and nothing was created" false (Sys.file_exists absent);
  let file = Filename.concat parent "file" in
  write_file file "workspace";
  not_written "a base path that is a file" (Revision.write_ledger ~base_path:file ledger);
  Alcotest.(check string) "and the file is unchanged" "workspace" (read_file file))

let test_write_refuses_a_symbolic_link_below_the_base () = with_base (fun base_path ->
  with_base (fun elsewhere ->
    Unix.symlink elsewhere (Filename.concat base_path ".masc");
    not_written "a .masc that is a symbolic link" (Revision.write_ledger ~base_path ledger);
    Alcotest.(check (list string)) "and nothing was written through it" []
      (Array.to_list (Sys.readdir elsewhere))))

let test_write_creates_a_removed_revision_directory_again () = with_base (fun base_path ->
  let revision = ledger_revision base_path in
  remove (revisions base_path);
  let again = ledger_revision base_path in
  Alcotest.(check string) "the same revision" (Revision.ledger_sha256 revision) (Revision.ledger_sha256 again);
  Alcotest.check json "and it reads back from the directory created again"
    (Ledger.to_json ledger) (Ledger.to_json (read_back (Revision.read_ledger ~base_path again))))

let test_a_write_that_fails_is_an_error () =
  (* Root writes through directory permissions. *)
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_base (fun base_path ->
    let file = ledger_file base_path (ledger_revision base_path) in
    let directory = Filename.dirname file in
    Unix.chmod directory 0o500;
    Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
      not_written "a revision directory that refuses new files" (Revision.write_ledger ~base_path Ledger.empty);
      Alcotest.(check (list string)) "and it holds only the earlier file"
        [Filename.basename file] (Array.to_list (Sys.readdir directory))))

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

let () =
  Alcotest.run "workspace_memory_revision"
    [ ( "store"
      , [ Alcotest.test_case "a ledger revision is the bytes save writes" `Quick
            test_ledger_revision_is_the_bytes_save_writes
        ; Alcotest.test_case "write receipt binds the physical workspace" `Quick
            test_write_receipt_binds_the_physical_workspace
        ; Alcotest.test_case "one state is one file, written every time" `Quick
            test_one_state_is_one_file_written_every_time
        ; Alcotest.test_case "states read back" `Quick test_states_read_back
        ; Alcotest.test_case "a Briefing revision is key-sorted, not the published file" `Quick
            test_briefing_revision_is_key_sorted_not_the_published_file
        ; Alcotest.test_case "Briefing bytes are compact with sorted keys" `Quick
            test_briefing_bytes_are_compact_with_sorted_keys
        ; Alcotest.test_case "a missing file is not an empty state" `Quick
            test_missing_file_is_not_an_empty_state
        ; Alcotest.test_case "damaged files are refused until written again" `Quick
            test_damaged_files_are_refused_until_written_again
        ; Alcotest.test_case "a file must decode as its kind and revision" `Quick
            test_a_file_must_decode_as_its_kind_and_revision
        ; Alcotest.test_case "something other than a file is unreadable" `Quick
            test_something_other_than_a_file_is_unreadable ] )
    ; ( "write"
      , [ Alcotest.test_case "writing needs a workspace directory" `Quick
            test_write_needs_a_workspace_directory
        ; Alcotest.test_case "a symbolic link below the base is refused" `Quick
            test_write_refuses_a_symbolic_link_below_the_base
        ; Alcotest.test_case "a removed revision directory is created again" `Quick
            test_write_creates_a_removed_revision_directory_again
        ; Alcotest.test_case "a write that fails is an error" `Quick test_a_write_that_fails_is_an_error ] )
    ; ("codec", [ Alcotest.test_case "revision references" `Quick test_revision_json ]) ]
