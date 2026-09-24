(* A sandbox image tag names one build of one recipe (RFC
   keeper-sandbox-images-have-versions §2.2). These cases pin what makes two
   tags differ, and that the recipes in this repository list every file their
   COPY lines need. *)

open Alcotest
module V = Keeper_sandbox_image_version
open V

(* 2026-09-24T11:30:45Z and ten seconds later, the same UTC minute. *)
let built_at = 1790249445.0
let same_minute = built_at +. 10.0
let next_minute = built_at +. 60.0

let recipe ?(dockerfile = "FROM scratch\n") ?(inputs = []) name =
  { V.name; dockerfile; inputs }

let input path contents = { V.path; contents }

let hash_suffix tag =
  match String.rindex_opt tag '-' with
  | Some i -> String.sub tag (i + 1) (String.length tag - i - 1)
  | None -> fail ("no hash in " ^ tag)

let test_tag_names_recipe_minute_and_hash () =
  let r = recipe "base" in
  let hash = V.inputs_sha256 r in
  check string "shape"
    ("masc-sandbox-base:20260924T1130Z-" ^ String.sub hash 0 V.tag_hash_prefix_length)
    (V.tag ~built_at r);
  check int "full hash is hex sha256" 64 (String.length hash)

let test_same_recipe_same_minute_same_tag () =
  let r = recipe "base" in
  check string "one build per minute" (V.tag ~built_at r) (V.tag ~built_at:same_minute r)

let test_another_minute_is_another_tag () =
  let r = recipe "base" in
  let earlier = V.tag ~built_at r and later = V.tag ~built_at:next_minute r in
  check bool "tags differ" false (String.equal earlier later);
  check string "hash is the same" (hash_suffix earlier) (hash_suffix later)

let test_every_input_moves_the_hash () =
  let base = recipe ~inputs:[ input "masc.opam" "a" ] "ocaml" in
  let differs label other =
    check bool label false (String.equal (V.inputs_sha256 base) (V.inputs_sha256 other))
  in
  differs "dockerfile" { base with dockerfile = "FROM scratch\n#\n" };
  differs "input contents" { base with inputs = [ input "masc.opam" "b" ] };
  differs "input path" { base with inputs = [ input "masc.opam.locked" "a" ] };
  differs "extra input" { base with inputs = [ input "masc.opam" "a"; input "x" "" ] }

(* Without length framing, a path ending "a" followed by contents "bc" and a
   path ending "ab" followed by "c" would feed the hash the same bytes. *)
let test_framing_keeps_boundaries () =
  let one = recipe ~inputs:[ input "a" "bc" ] "x" in
  let two = recipe ~inputs:[ input "ab" "c" ] "x" in
  check bool "different split, different hash" false
    (String.equal (V.inputs_sha256 one) (V.inputs_sha256 two))

let test_labels_carry_version_and_full_hash () =
  let r = recipe "base" in
  let tag = V.tag ~built_at r in
  let version = V.version ~built_at r in
  check string "version is the tag's own part" tag (V.repository r ^ ":" ^ version);
  let labels = V.labels ~version ~built_at r in
  check (option string) "version" (Some version)
    (List.assoc_opt "org.opencontainers.image.version" labels);
  check (option string) "a named tag labels itself" (Some "fixture:requested")
    (List.assoc_opt "org.opencontainers.image.version"
       (V.labels ~version:"fixture:requested" ~built_at r));
  check (option string) "created" (Some "2026-09-24T11:30:45Z")
    (List.assoc_opt "org.opencontainers.image.created" labels);
  check (option string) "recipe" (Some "base") (List.assoc_opt "masc.sandbox.recipe" labels);
  check (option string) "hash" (Some (V.inputs_sha256 r))
    (List.assoc_opt "masc.sandbox.inputs_sha256" labels)

let test_base_is_carried () =
  check string "name" "base" V.base_embedded.name;
  check string "same bytes as the embedded recipe" Keeper_sandbox_image.dockerfile
    V.base_embedded.dockerfile;
  check int "no inputs" 0 (List.length V.base_embedded.inputs)

(* A throwaway checkout: sandbox-images/<name>/ plus whatever the case writes. *)
let with_source files f =
  let root = Filename.temp_file "masc-sandbox-version-" ".d" in
  Sys.remove root;
  Sys.mkdir root 0o700;
  let rec mkdirs dir =
    if not (Sys.file_exists dir) then (mkdirs (Filename.dirname dir); Sys.mkdir dir 0o700)
  in
  List.iter
    (fun (path, contents) ->
       let full = Filename.concat root path in
       mkdirs (Filename.dirname full);
       Out_channel.with_open_bin full (fun oc -> output_string oc contents))
    files;
  (* A target may be removed before its in-checkout symlink in readdir order. *)
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      Array.iter (fun e -> remove (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path
    | _ -> Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let load_error = testable (fun fmt e -> Format.pp_print_string fmt (V.load_error_to_string e)) ( = )

let test_load_reads_inputs_in_listed_order () =
  with_source
    [ "sandbox-images/tool/Dockerfile", "FROM scratch\nCOPY b a /x/\n"
    ; "sandbox-images/tool/inputs", "# comment\n\nb\n  a  \n"
    ; "a", "A"
    ; "b", "B"
    ]
    (fun source ->
       match V.load ~source ~name:"tool" with
       | Error e -> fail (V.load_error_to_string e)
       | Ok r ->
         check (list string) "order" [ "b"; "a" ] (List.map (fun (i : V.input) -> i.path) r.inputs);
         check (list string) "contents" [ "B"; "A" ]
           (List.map (fun (i : V.input) -> i.contents) r.inputs))

let test_load_without_inputs_file () =
  with_source [ "sandbox-images/tool/Dockerfile", "FROM scratch\n" ] (fun source ->
    match V.load ~source ~name:"tool" with
    | Ok r -> check int "no inputs" 0 (List.length r.inputs)
    | Error e -> fail (V.load_error_to_string e))

let expect_error label expected result =
  match result with
  | Ok _ -> fail (label ^ ": loaded")
  | Error e -> check load_error label expected e

let test_load_refusals () =
  with_source
    [ "sandbox-images/up/Dockerfile", "FROM scratch\n"
    ; "sandbox-images/up/inputs", "../outside\n"
    ; "sandbox-images/gone/Dockerfile", "FROM scratch\n"
    ; "sandbox-images/gone/inputs", "missing.txt\n"
    ; "sandbox-images/self/Dockerfile", "FROM scratch\n"
    ; "sandbox-images/self/inputs", "Dockerfile\n"
    ]
    (fun source ->
       let root = Unix.realpath source in
       let inputs_of name = Filename.concat (Filename.concat (Filename.concat root "sandbox-images") name) "inputs" in
       expect_error "bad name" (V.Invalid_name "Base") (V.load ~source ~name:"Base");
       expect_error "leading dash" (V.Invalid_name "-x") (V.load ~source ~name:"-x");
       expect_error "no recipe"
         (V.Recipe_missing
            { path = Filename.concat (Filename.concat (Filename.concat root "sandbox-images") "nope") "Dockerfile" })
         (V.load ~source ~name:"nope");
       expect_error "climbs out"
         (V.Input_path_rejected { listed_in = inputs_of "up"; path = "../outside" })
         (V.load ~source ~name:"up");
       expect_error "missing input"
         (V.Input_missing { listed_in = inputs_of "gone"; path = "missing.txt" })
         (V.load ~source ~name:"gone");
       expect_error "the recipe's own name"
         (V.Input_path_rejected { listed_in = inputs_of "self"; path = "Dockerfile" })
         (V.load ~source ~name:"self"))

(* A link inside the checkout that points outside it would carry that file
   into the image; docker itself does not follow links out of its context. *)
let test_load_refuses_a_link_out_of_the_checkout () =
  with_source [ "outside/secret", "s" ] (fun outer ->
    let secret = Filename.concat (Filename.concat outer "outside") "secret" in
    with_source
      [ "sandbox-images/leak/Dockerfile", "FROM scratch\n"
      ; "sandbox-images/leak/inputs", "link\n"
      ]
      (fun source ->
         Unix.symlink secret (Filename.concat source "link");
         let inputs = Filename.concat (Filename.concat (Filename.concat (Unix.realpath source) "sandbox-images") "leak") "inputs" in
         expect_error "link out"
           (V.Input_outside_source { listed_in = inputs; path = "link" })
           (V.load ~source ~name:"leak")))

let test_load_refuses_recipe_files_linked_outside_checkout () =
  with_source
    [ "outside/Dockerfile", "FROM scratch\n"
    ; "outside/inputs", "file.txt\n"
    ]
    (fun outer ->
      with_source [ "sandbox-images/leak/inputs", "" ] (fun source ->
        let recipe = Filename.concat source "sandbox-images/leak/Dockerfile" in
        Unix.symlink (Filename.concat outer "outside/Dockerfile") recipe;
        let actual = Filename.concat (Unix.realpath source) "sandbox-images/leak/Dockerfile" in
        expect_error "Dockerfile link out"
          (V.Source_file_outside_source { path = actual })
          (V.load ~source ~name:"leak"));
      with_source [ "sandbox-images/leak/Dockerfile", "FROM scratch\n" ] (fun source ->
        let manifest = Filename.concat source "sandbox-images/leak/inputs" in
        Unix.symlink (Filename.concat outer "outside/inputs") manifest;
        let actual = Filename.concat (Unix.realpath source) "sandbox-images/leak/inputs" in
        expect_error "inputs manifest link out"
          (V.Source_file_outside_source { path = actual })
          (V.load ~source ~name:"leak")))

let test_load_keeps_links_to_files_inside_checkout () =
  with_source
    [ "sandbox-images/inside/inputs", "linked-input\n"
    ; "recipe-template", "FROM scratch\n"
    ; "input-template", "content"
    ]
    (fun source ->
      Unix.symlink (Filename.concat source "recipe-template")
        (Filename.concat source "sandbox-images/inside/Dockerfile");
      Unix.symlink (Filename.concat source "input-template")
        (Filename.concat source "linked-input");
      match V.load ~source ~name:"inside" with
      | Ok recipe ->
        check string "the recipe's in-checkout link" "FROM scratch\n" recipe.dockerfile;
        check (list string) "the listed input's in-checkout link" [ "content" ]
          (List.map (fun (input : V.input) -> input.contents) recipe.inputs)
      | Error error -> fail (V.load_error_to_string error))

let test_write_context_places_inputs () =
  let r = recipe ~dockerfile:"FROM scratch\n" ~inputs:[ input "scripts/x.sh" "echo" ] "t" in
  with_source [] (fun dir ->
    let dockerfile =
      match V.write_context ~dir r with
      | Ok path -> path
      | Error e -> fail (V.load_error_to_string e)
    in
    check string "dockerfile" "FROM scratch\n" (In_channel.with_open_bin dockerfile In_channel.input_all);
    check string "nested input" "echo"
      (In_channel.with_open_bin (Filename.concat dir "scripts/x.sh") In_channel.input_all))

(* The repository's own recipes: every COPY source is a listed input, so the
   build context carries it and its bytes are in the tag. *)
let rec find_source_root dir hops =
  if Sys.file_exists (Filename.concat dir "sandbox-images/ocaml/Dockerfile") then Some dir
  else if hops = 0 then None
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root parent (hops - 1)

let copy_sources dockerfile =
  String.split_on_char '\n' dockerfile
  |> List.filter_map (fun line ->
    match String.split_on_char ' ' (String.trim line) |> List.filter (fun w -> w <> "") with
    | "COPY" :: rest ->
      let args = List.filter (fun w -> not (String.length w > 2 && String.sub w 0 2 = "--")) rest in
      (match List.rev args with
       | _destination :: sources -> Some (List.rev sources)
       | [] -> None)
    | _ -> None)
  |> List.concat

let test_repository_recipes_list_their_copy_sources () =
  match find_source_root (Sys.getcwd ()) 8 with
  | None -> fail ("sandbox-images/ not found above " ^ Sys.getcwd ())
  | Some source ->
    List.iter
      (fun name ->
         match V.load ~source ~name with
         | Error e -> fail (V.load_error_to_string e)
         | Ok r ->
           let listed = List.map (fun (i : V.input) -> i.path) r.inputs in
           List.iter
             (fun src ->
                check bool (Printf.sprintf "%s lists %s" name src) true (List.mem src listed))
             (copy_sources r.dockerfile))
      [ "base"; "ocaml" ]

let () =
  run "Sandbox image version"
    [ ( "tag"
      , [ test_case "names recipe, minute and hash" `Quick test_tag_names_recipe_minute_and_hash
        ; test_case "same recipe, same minute, same tag" `Quick test_same_recipe_same_minute_same_tag
        ; test_case "another minute is another tag" `Quick test_another_minute_is_another_tag
        ; test_case "every input moves the hash" `Quick test_every_input_moves_the_hash
        ; test_case "framing keeps boundaries" `Quick test_framing_keeps_boundaries
        ; test_case "labels carry version and full hash" `Quick
            test_labels_carry_version_and_full_hash
        ; test_case "base is carried in the binary" `Quick test_base_is_carried
        ] )
    ; ( "load"
      , [ test_case "reads inputs in listed order" `Quick test_load_reads_inputs_in_listed_order
        ; test_case "no inputs file means no inputs" `Quick test_load_without_inputs_file
        ; test_case "refusals are typed" `Quick test_load_refusals
        ; test_case "a link out of the checkout is refused" `Quick
            test_load_refuses_a_link_out_of_the_checkout
        ; test_case "recipe and manifest links out of the checkout are refused" `Quick
            test_load_refuses_recipe_files_linked_outside_checkout
        ; test_case "links to files inside the checkout still load" `Quick
            test_load_keeps_links_to_files_inside_checkout
        ; test_case "write_context places nested inputs" `Quick test_write_context_places_inputs
        ; test_case "repository recipes list their COPY sources" `Quick
            test_repository_recipes_list_their_copy_sources
        ] )
    ]
