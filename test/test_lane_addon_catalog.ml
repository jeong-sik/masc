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
    write {|id = "independent-package"
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
|};
    let load_package ~path = Masc.Lane_addon_manifest.load ~path
      |> Result.map_error Masc.Lane_addon_manifest.error_to_string
      |> Result.map (fun (package : Masc.Lane_addon_types.package) -> Catalog.{title=package.title;revision=package.revision;
          description=package.presentation.description}) in
    let read ()=Catalog.discover ~base_path:root ~directory:None ~load_package |> ok in
    (match (read ()).entries with
     | [Catalog.Package package] ->
         check string "title comes from manifest" "A manifest-defined title" package.metadata.title;
         check string "revision comes from manifest" "revision-2" package.metadata.revision
     | _ -> fail "valid manifest did not become a selectable package");
    write "id = [";
    check bool "malformed manifest becomes an explicit issue" true (match (read ()).entries with
      | [Catalog.Issue _] -> true | _ -> false))
let () = run "Package catalog manifest integration" ["manifest",[
  test_case "real parser controls selectable metadata" `Quick real_manifests]]
