(** Real manifest loader integration; no image inspection or worker startup. *)
open Alcotest
module Catalog = Masc.Lane_addon_catalog
let ok = function Ok value -> value | Error message -> fail message
let real_manifests () =
  let root=Filename.temp_file "masc-manifest-catalog-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let path=Filename.concat root "lane.toml" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path;Unix.rmdir root) (fun () ->
    let write text=Out_channel.with_open_bin path (fun c -> output_string c text) in
    let manifest = {|id = "independent-package"
revision = "revision-2"
title = "A manifest-defined title"
image = "fixture/image"
command = ["observer"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
|} in
    write ("ui_category = \"analysis\"\n" ^ manifest);
    let load_package ~path = Masc.Lane_addon_manifest.load ~path
      |> Result.map_error Masc.Lane_addon_manifest.error_to_string
      |> Result.map (fun (package : Masc.Lane_addon_types.package) -> Catalog.{title=package.title;revision=package.revision;
          description=package.presentation.description;ui_category=package.ui_category}) in
    let read ()=Catalog.discover ~base_path:root ~directory:None ~load_package |> ok in
    let original = read () in
    (match original.entries with
     | [Catalog.Package package] ->
         check string "title comes from manifest" "A manifest-defined title" package.metadata.title;
         check string "revision comes from manifest" "revision-2" package.metadata.revision;
         check bool "current category comes from the actual manifest" true
           (package.metadata.ui_category=Some Masc.Lane_addon_category.Analysis)
     | _ -> fail "valid manifest did not become a selectable package");
    check bool "catalog codec preserves typed category and original metadata" true
      (Catalog.of_json (Catalog.to_json original) |> ok = original);
    let changed value = match Catalog.to_json original with
      | `Assoc fields -> `Assoc (List.map (function
          | "entries",`List [`Assoc entry] -> "entries",`List [`Assoc
              (("ui_category",value)::List.remove_assoc "ui_category" entry)]
          | field -> field) fields)
      | _ -> fail "catalog did not encode an object" in
    List.iter (fun value -> check bool "invalid declared catalog category is not unclassified" true
      (Result.is_error (Catalog.of_json (changed value))))
      [`String "unsupported";`String "";`Null;`Bool true;`List [`String "analysis"]];
    let duplicate = match changed (`String "analysis") with
      | `Assoc fields -> `Assoc (List.map (function
          | "entries",`List [`Assoc entry] -> "entries",`List [`Assoc
              (("ui_category",`String "browser")::entry)]
          | field -> field) fields)
      | _ -> fail "catalog did not encode an object" in
    check bool "duplicate declared catalog category is refused" true
      (Result.is_error (Catalog.of_json duplicate));
    write ("ui_category = \"voice_media\"\n" ^ manifest);
    (match (read ()).entries with
     | [Catalog.Package package] -> check bool "catalog observes a category edit without starting a worker" true
         (package.metadata.ui_category=Some Masc.Lane_addon_category.Voice_and_media)
     | _ -> fail "updated category disappeared from catalog");
    write ("ui_category = \"unsupported\"\n" ^ manifest);
    check bool "unsupported manifest category remains a visible package issue" true
      (match (read ()).entries with [Catalog.Issue _] -> true | _ -> false);
    write manifest;
    (match (read ()).entries with
     | [Catalog.Package package] -> check bool "omitted category alone means unclassified" true
         (package.metadata.ui_category=None)
     | _ -> fail "unclassified manifest disappeared from catalog");
    write "id = [";
    check bool "malformed manifest becomes an explicit issue" true (match (read ()).entries with
      | [Catalog.Issue _] -> true | _ -> false))
let () = run "Package catalog manifest integration" ["manifest",[
  test_case "real parser controls selectable metadata" `Quick real_manifests]]
