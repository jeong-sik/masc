(* The image catalog a Keeper's sandbox_image name is looked up in (RFC
   keeper-sandbox-images-have-versions §2.3). A name either resolves to one
   pinned build for the store asked about, or says precisely why not; a
   malformed catalog is refused rather than read around; a change is written
   only over the file it was read from. *)

open Alcotest
open Keeper_sandbox_image_catalog

let digest c = "sha256:" ^ String.make 64 c
let apple = Microvm Keeper_microvm_backend.Apple_container
let ocaml_now = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"
let ocaml_before = "masc-sandbox-ocaml:20260921T0517Z-9b04e6d1"

let parsed text =
  match parse text with
  | Ok catalog -> catalog
  | Error e -> fail (parse_error_to_string e)

let refused label text =
  match parse text with
  | Ok _ -> fail (label ^ ": parsed")
  | Error e -> e

let promoted_ocaml =
  Printf.sprintf
    {|[images.base]

[images.ocaml.apple_container]
reference = "%s"
digest = "%s"
previous = { reference = "%s", digest = "%s" }
|}
    ocaml_now (digest 'a') ocaml_before (digest 'b')

(* [pinned] is private, so expectations are spelt as text. *)
let describe = function
  | Resolved p -> Printf.sprintf "Resolved %s %s" p.reference p.digest
  | Unknown_image { name; known } ->
    Printf.sprintf "Unknown_image %s [%s]" name (String.concat ";" known)
  | Not_built_on_host { name; store } ->
    Printf.sprintf "Not_built_on_host %s %s" name (store_to_string store)

let resolves label expected catalog ~name ~store =
  check string label expected (describe (resolve catalog ~name ~store))

let test_a_promoted_name_resolves_for_its_store () =
  let catalog = parsed promoted_ocaml in
  resolves "apple_container" ("Resolved " ^ ocaml_now ^ " " ^ digest 'a') catalog ~name:"ocaml"
    ~store:apple;
  resolves "docker has nothing built" "Not_built_on_host ocaml docker" catalog ~name:"ocaml"
    ~store:Docker_daemon

let test_a_name_with_no_build_is_not_built_on_host () =
  resolves "base" "Not_built_on_host base apple_container" (parsed promoted_ocaml) ~name:"base"
    ~store:apple

let test_an_unknown_name_lists_the_known_ones () =
  resolves "rust" "Unknown_image rust [base;ocaml]" (parsed promoted_ocaml) ~name:"rust"
    ~store:apple

let test_previous_is_kept () =
  match entries (parsed promoted_ocaml) with
  | [ base; ocaml ] ->
    check int "base has no builds" 0 (List.length base.promoted);
    (match ocaml.promoted with
     | [ (store, promotion) ] ->
       check string "store" "apple_container" (store_to_string store);
       check (option string) "previous" (Some ocaml_before)
         (Option.map (fun p -> p.reference) promotion.previous)
     | _ -> fail "one promotion expected")
  | _ -> fail "two entries expected"

let test_an_empty_catalog_knows_no_names () =
  resolves "empty" "Unknown_image base []" (parsed "") ~name:"base" ~store:Docker_daemon

let test_every_store_spelling_round_trips () =
  List.iter
    (fun store ->
       check (option string) (store_to_string store) (Some (store_to_string store))
         (Option.map store_to_string (store_of_string (store_to_string store))))
    (Docker_daemon :: List.map (fun b -> Microvm b) Keeper_microvm_backend.all)

let error = testable (fun fmt e -> Format.pp_print_string fmt (parse_error_to_string e)) ( = )
let store_path = [ "images"; "ocaml"; "apple_container" ]
let one_store body = "[images.ocaml.apple_container]\n" ^ body
let with_reference r = one_store (Printf.sprintf "reference = \"%s\"\ndigest = \"%s\"\n" r (digest 'a'))

let test_malformed_catalogs_are_refused () =
  let pinned_body = Printf.sprintf "reference = \"x:y\"\ndigest = \"%s\"\n" (digest 'a') in
  check error "unknown top-level key" (Unknown_key { path = []; key = "image" })
    (refused "top" "[image.base]\n");
  check error "misspelt field" (Unknown_key { path = store_path; key = "tag" })
    (refused "field" (one_store (pinned_body ^ "tag = \"z\"\n")));
  check error "unknown store" (Unknown_store { image = "ocaml"; store = "podman" })
    (refused "store" ("[images.ocaml.podman]\n" ^ pinned_body));
  check error "uppercase digest"
    (Invalid_digest { path = store_path; value = "sha256:" ^ String.make 64 'A' })
    (refused "digest"
       (one_store (Printf.sprintf "reference = \"x:y\"\ndigest = \"sha256:%s\"\n" (String.make 64 'A'))));
  check error "missing digest" (Missing_field { path = store_path; field = "digest" })
    (refused "missing" (one_store "reference = \"x:y\"\n"));
  check error "half a previous"
    (Missing_field { path = store_path @ [ "previous" ]; field = "digest" })
    (refused "previous" (one_store (pinned_body ^ "previous = { reference = \"x:z\" }\n")));
  check error "store is not a table" (Expected_table { path = store_path })
    (refused "scalar" "[images.ocaml]\napple_container = \"x:y\"\n");
  (match refused "syntax" "[images.base\n" with
   | Toml_syntax _ -> ()
   | other -> fail ("expected a syntax error, got " ^ parse_error_to_string other))

(* Names are the directories under sandbox-images/: words joined by one '-'. *)
let test_names_are_words_joined_by_single_dashes () =
  List.iter
    (fun name -> check error name (Invalid_name name) (refused name ("[images." ^ name ^ "]\n")))
    [ "Base"; "-x"; "a-"; "a--b" ];
  check int "a-b is a name" 1 (List.length (entries (parsed "[images.a-b]\n")))

(* A reference goes into a runtime's argv. Without a tag it would mean
   "latest", with a leading '-' it would read as a flag, and a digest belongs
   in the digest field. *)
let test_references_are_repository_and_tag () =
  List.iter
    (fun value ->
       check error value (Invalid_reference { path = store_path; value })
         (refused value (with_reference value)))
    [ " "
    ; "-v"
    ; "--privileged:x"
    ; "masc-sandbox-ocaml"
    ; "Masc:tag"
    ; "localhost:5000/foo"
    ; "x@sha256:" ^ String.make 64 'a'
    ; "x:-tag"
    ; "x:" ^ String.make 129 't'
    ];
  List.iter
    (fun value -> check int value 1 (List.length (entries (parsed (with_reference value)))))
    [ "masc-sandbox:general"; "localhost:5000/team/img:v1.2_rc-3"; ocaml_now ];
  check bool "is_reference agrees" false (is_reference "--privileged:x");
  check bool "is_reference accepts a tag" true (is_reference "masc-sandbox:general")

let changed label = function
  | Ok catalog -> catalog
  | Error e -> fail (label ^ ": " ^ change_error_to_string e)

let current catalog name store =
  match resolve catalog ~name ~store with
  | Resolved p -> Some p.reference
  | Unknown_image _ | Not_built_on_host _ -> None

let test_to_toml_round_trips () =
  let catalog = parsed promoted_ocaml in
  check string "parse (to_toml c) = c" (to_toml catalog) (to_toml (parsed (to_toml catalog)));
  check bool "same entries" true (entries (parsed (to_toml catalog)) = entries catalog)

let test_promote_keeps_what_it_replaced () =
  let next_ref = "masc-sandbox-ocaml:20260925T0900Z-11112222" in
  let next =
    changed "promote"
      (promote (parsed promoted_ocaml) ~name:"ocaml" ~store:apple ~reference:next_ref
         ~digest:(digest 'c'))
  in
  check (option string) "current" (Some next_ref) (current next "ocaml" apple);
  let back = changed "rollback" (rollback next ~name:"ocaml" ~store:apple) in
  check (option string) "rolled back" (Some ocaml_now) (current back "ocaml" apple);
  check (option string) "rolling back twice returns" (Some next_ref)
    (current (changed "again" (rollback back ~name:"ocaml" ~store:apple)) "ocaml" apple);
  check bool "promoting the current build again changes nothing" true
    (entries next
     = entries
         (changed "same"
            (promote next ~name:"ocaml" ~store:apple ~reference:next_ref ~digest:(digest 'c'))))

let test_first_promotion_and_other_stores () =
  let next =
    changed "base on docker"
      (promote (parsed promoted_ocaml) ~name:"base" ~store:Docker_daemon
         ~reference:"masc-sandbox:general" ~digest:(digest 'd'))
  in
  check (option string) "docker" (Some "masc-sandbox:general") (current next "base" Docker_daemon);
  check (option string) "apple untouched" None (current next "base" apple);
  check (option string) "ocaml untouched" (Some ocaml_now) (current next "ocaml" apple)

let test_changes_are_refused_with_reasons () =
  let catalog = parsed promoted_ocaml in
  (match promote catalog ~name:"rust" ~store:apple ~reference:"r:1" ~digest:(digest 'a') with
   | Error (No_such_image { name = "rust"; known = [ "base"; "ocaml" ] }) -> ()
   | _ -> fail "an unknown name was promoted");
  (match promote catalog ~name:"base" ~store:apple ~reference:"r:1" ~digest:"sha256:short" with
   | Error (Invalid_pin (Invalid_digest _)) -> ()
   | _ -> fail "a bad digest was promoted");
  (match promote catalog ~name:"base" ~store:apple ~reference:"-v" ~digest:(digest 'a') with
   | Error (Invalid_pin (Invalid_reference _)) -> ()
   | _ -> fail "a flag was promoted as a reference");
  match rollback catalog ~name:"base" ~store:apple with
  | Error (Nothing_to_roll_back _) -> ()
  | _ -> fail "rolled back a name with no build"

let with_dir f =
  let dir = Filename.temp_file "masc-image-catalog-" ".d" in
  Sys.remove dir;
  Sys.mkdir dir 0o700;
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun e -> remove (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> f dir)

let write_catalog config_root text =
  Out_channel.with_open_bin (Filename.concat config_root file_name) (fun oc -> output_string oc text)

let for_change label ~config_root ~shipped =
  match load_for_change ~config_root ~shipped with
  | Ok pair -> pair
  | Error e -> fail (label ^ ": " ^ load_error_to_string e)

let saved label = function
  | Ok () -> ()
  | Error e -> fail (label ^ ": " ^ save_error_to_string e)

let test_load_reads_the_config_root () =
  with_dir (fun config_root ->
    (match load ~config_root with
     | Error (Missing { path }) -> check string "path" (Filename.concat config_root file_name) path
     | Error e -> fail (load_error_to_string e)
     | Ok _ -> fail "loaded a catalog that is not there");
    write_catalog config_root promoted_ocaml;
    match load ~config_root with
    | Ok catalog -> check int "entries" 2 (List.length (entries catalog))
    | Error e -> fail (load_error_to_string e))

let test_a_host_without_a_catalog_starts_from_the_shipped_one () =
  with_dir (fun config_root ->
    let shipped = Some "[images.base]\n" in
    let catalog, snapshot = for_change "shipped" ~config_root ~shipped in
    check (list string) "names" [ "base" ] (List.map (fun e -> e.name) (entries catalog));
    (match load_for_change ~config_root ~shipped:None with
     | Error (Missing _) -> ()
     | _ -> fail "no host file and nothing shipped should be Missing");
    let next =
      changed "promote"
        (promote catalog ~name:"base" ~store:apple ~reference:"masc-sandbox:general"
           ~digest:(digest 'e'))
    in
    saved "first save" (save ~config_root ~expected:snapshot next);
    match load ~config_root with
    | Ok loaded -> check (option string) "written" (Some "masc-sandbox:general") (current loaded "base" apple)
    | Error e -> fail (load_error_to_string e))

let test_a_stale_writer_writes_nothing () =
  with_dir (fun config_root ->
    write_catalog config_root promoted_ocaml;
    let first, first_seen = for_change "first" ~config_root ~shipped:None in
    let second, second_seen = for_change "second" ~config_root ~shipped:None in
    saved "first writer"
      (save ~config_root ~expected:first_seen
         (changed "a" (rollback first ~name:"ocaml" ~store:apple)));
    (match
       save ~config_root ~expected:second_seen
         (changed "b"
            (promote second ~name:"base" ~store:apple ~reference:"masc-sandbox:general"
               ~digest:(digest 'f')))
     with
     | Error (Changed_since_read _) -> ()
     | Ok () -> fail "the stale writer overwrote the first change"
     | Error e -> fail (save_error_to_string e));
    match load ~config_root with
    | Ok loaded ->
      check (option string) "the first change stands" (Some ocaml_before) (current loaded "ocaml" apple);
      check (option string) "the stale change is absent" None (current loaded "base" apple)
    | Error e -> fail (load_error_to_string e))

(* The copy the binary carries names images and promotes nothing: builds are
   the host's to record. *)
let rec find_source_root dir hops =
  if Sys.file_exists (Filename.concat dir "config/sandbox-images.toml") then Some dir
  else if hops = 0 then None
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root parent (hops - 1)

let test_the_shipped_catalog_promotes_nothing () =
  match find_source_root (Sys.getcwd ()) 8 with
  | None -> fail ("config/sandbox-images.toml not found above " ^ Sys.getcwd ())
  | Some root ->
    let text =
      In_channel.with_open_bin (Filename.concat root "config/sandbox-images.toml") In_channel.input_all
    in
    let catalog = parsed text in
    check (list string) "names" [ "base"; "ocaml" ] (List.map (fun e -> e.name) (entries catalog));
    check bool "nothing promoted" true (List.for_all (fun e -> e.promoted = []) (entries catalog))

let () =
  run "Sandbox image catalog"
    [ ( "resolve"
      , [ test_case "a promoted name resolves for its store" `Quick
            test_a_promoted_name_resolves_for_its_store
        ; test_case "a name with no build is not built on host" `Quick
            test_a_name_with_no_build_is_not_built_on_host
        ; test_case "an unknown name lists the known ones" `Quick
            test_an_unknown_name_lists_the_known_ones
        ; test_case "previous is kept" `Quick test_previous_is_kept
        ; test_case "an empty catalog knows no names" `Quick test_an_empty_catalog_knows_no_names
        ; test_case "every store spelling round-trips" `Quick test_every_store_spelling_round_trips
        ] )
    ; ( "parse"
      , [ test_case "malformed catalogs are refused" `Quick test_malformed_catalogs_are_refused
        ; test_case "names are words joined by single dashes" `Quick
            test_names_are_words_joined_by_single_dashes
        ; test_case "references are repository and tag" `Quick
            test_references_are_repository_and_tag
        ; test_case "the shipped catalog promotes nothing" `Quick
            test_the_shipped_catalog_promotes_nothing
        ] )
    ; ( "change"
      , [ test_case "to_toml round-trips" `Quick test_to_toml_round_trips
        ; test_case "promote keeps what it replaced" `Quick test_promote_keeps_what_it_replaced
        ; test_case "first promotion and other stores" `Quick test_first_promotion_and_other_stores
        ; test_case "changes are refused with reasons" `Quick test_changes_are_refused_with_reasons
        ] )
    ; ( "load and save"
      , [ test_case "load reads the config root" `Quick test_load_reads_the_config_root
        ; test_case "a host without a catalog starts from the shipped one" `Quick
            test_a_host_without_a_catalog_starts_from_the_shipped_one
        ; test_case "a stale writer writes nothing" `Quick test_a_stale_writer_writes_nothing
        ] )
    ]
