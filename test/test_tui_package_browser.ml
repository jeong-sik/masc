open Alcotest
module Catalog = Masc.Lane_addon_catalog
module Browser = Masc_tui_package_browser
let ok = function Ok value -> value | Error message -> fail message
let metadata = Catalog.{title="Readable package";revision="rev-a";description=Some "Actual input choices"}
let write path contents = Out_channel.with_open_bin path (fun channel -> output_string channel contents)
let temporary f =
  let root = Filename.temp_file "masc-package-discovery-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | _ -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f (Unix.realpath root))

let discover_workspace () = temporary (fun root ->
  let child name = let path=Filename.concat root name in Unix.mkdir path 0o700;path in
  let package=child "package" and empty=child "empty" and broken=child "invalid" in
  let nested=Filename.concat package "nested" in Unix.mkdir nested 0o700;
  write (Filename.concat package "lane.toml") "manifest bytes";
  write (Filename.concat nested "lane.toml") "nested bytes";
  write (Filename.concat broken "lane.toml") "invalid bytes";
  let reads=ref [] in
  let load_package ~path = reads:=path::!reads;
    if Filename.dirname path=broken then Error "Invalid package manifest" else Ok metadata in
  let result=Catalog.discover ~base_path:root ~directory:None ~load_package |> ok in
  check (option string) "root has no parent" None result.parent;
  check (list string) "only immediate manifests read" [Filename.concat broken "lane.toml";Filename.concat package "lane.toml"] (List.sort String.compare !reads);
  check bool "invalid folder stays navigable" true (List.mem (Catalog.Folder broken) result.entries);
  check bool "empty folder stays navigable" true (List.mem (Catalog.Folder empty) result.entries);
  check bool "invalid manifest remains an issue" true (List.exists (function Catalog.Issue i -> i.message="Invalid package manifest" | _ -> false) result.entries);
  check bool "JSON preserves snapshot" true (Catalog.of_json (Catalog.to_json result) |> ok = result);
  let entered=Catalog.discover ~base_path:root ~directory:(Some "package") ~load_package |> ok in
  check (option string) "parent stays inside root" (Some root) entered.parent;
  check int "package and nested package appear" 2 (List.length entered.entries);
  let empty_snapshot=Catalog.discover ~base_path:root ~directory:(Some empty) ~load_package |> ok in
  check int "empty is successful with zero entries" 0 (List.length empty_snapshot.entries);
  check bool "read failure is not empty" true (Result.is_error (Catalog.discover ~base_path:root ~directory:(Some "missing") ~load_package)))

let containment () = temporary (fun root -> temporary (fun outside ->
  write (Filename.concat outside "lane.toml") "must not be loaded";
  Unix.symlink outside (Filename.concat root "escape");
  Unix.symlink (Filename.concat outside "lane.toml") (Filename.concat root "lane.toml");
  let reads=ref [] in let load_package ~path=reads:=path::!reads;Ok metadata in
  let snapshot=Catalog.discover ~base_path:root ~directory:None ~load_package |> ok in
  check (list string) "no escaped manifest load" [] !reads;
  check int "both escape issues remain visible" 2 (List.length snapshot.entries);
  List.iter (fun directory -> check bool "cannot navigate outside" true
    (Result.is_error (Catalog.discover ~base_path:root ~directory:(Some directory) ~load_package)))
    [outside;Filename.concat root "escape";"../" ^ Filename.basename outside];
  Sys.remove (Filename.concat root "lane.toml");
  Unix.symlink (Filename.concat root "absent") (Filename.concat root "lane.toml");
  let snapshot=Catalog.discover ~base_path:root ~directory:None ~load_package |> ok in
  check bool "dangling manifest is an issue" true (List.exists (function
    | Catalog.Issue i -> i.path=Filename.concat root "lane.toml" | _ -> false) snapshot.entries)))

let move key state = match Browser.handle ~key state |> ok with
  | Browser.Updated state -> state | _ -> fail "expected selection change"
let navigation () =
  let snapshot=Catalog.{directory="/workspace/packages";parent=Some "/workspace";
    entries=[Folder "/workspace/packages/nested";Package {manifest_path="/workspace/packages/p/lane.toml";metadata};Issue {path="/workspace/packages/bad/lane.toml";message="parse failed"}]} in
  let state=Browser.receive (Catalog.to_json snapshot) (Browser.create ()) |> ok in
  (match Browser.handle ~key:"enter" state |> ok with Browse (Some path) -> check string "folder navigation" "/workspace/packages/nested" path | _ -> fail "folder did not open");
  let state=move "j" state in
  (match Browser.handle ~key:"enter" state |> ok with Preview path -> check string "fresh preview of selected manifest" "/workspace/packages/p/lane.toml" path | _ -> fail "missing preview");
  (match Browser.handle ~key:"right" state |> ok with Browse (Some path) -> check string "package directory remains navigable" "/workspace/packages/p" path | _ -> fail "missing package directory");
  (match Browser.handle ~key:"left" state |> ok with Browse (Some path) -> check string "parent" "/workspace" path | _ -> fail "missing parent");
  let reordered={snapshot with entries=List.rev snapshot.entries} in
  let state=Browser.receive (Catalog.to_json reordered) state |> ok in
  check (option string) "refresh preserves exact selected manifest" (Some "/workspace/packages/p/lane.toml") (Browser.selected_manifest state);
  let bad=move "home" state in
  check bool "issue is not installable" true (Result.is_error (Browser.handle ~key:"enter" bad));
  check bool "manual path remains available" true (Browser.handle ~key:"p" state = Ok Browser.Manual);
  check bool "directory jump available" true (Browser.handle ~key:"g" state = Ok Browser.Jump);
  check bool "n opens the raw TOML declaration editor" true (Browser.handle ~key:"n" state = Ok Browser.Declare);
  check bool "unknown response does not fabricate entries" true (Result.is_error (Browser.receive (`Assoc []) state))

let reachable_large_list () =
  let snapshot=Catalog.{directory="/workspace";parent=None;entries=List.init 100 (fun i -> Folder (Printf.sprintf "/workspace/folder-%03d" i))} in
  let state=Browser.receive (Catalog.to_json snapshot) (Browser.create ()) |> ok |> move "end" in
  let lines=Browser.lines ~height:12 ~render:(fun s->[s]) state in
  check bool "selected last row visible in short frame" true (List.exists ((=) "> Folder  folder-099") (List.take 12 lines));
  (match Browser.handle ~key:"enter" state |> ok with Browse (Some path) -> check string "last folder opens" "/workspace/folder-099" path | _ -> fail "last row unreachable");
  check bool "root cannot navigate above workspace" true (match Browser.handle ~key:"left" state |> ok with Updated _ -> true | _ -> false)

let unread_remembered_folder () =
  let remembered=Browser.create ~directory:"/workspace/removed" () in
  (match Browser.handle ~key:"left" remembered |> ok with
   | Browse None -> () | _ -> fail "an unread remembered folder must reach the workspace root");
  check bool "reload still retries the remembered folder" true
    (Browser.handle ~key:"r" remembered = Ok (Browser.Browse (Some "/workspace/removed")));
  check string "footer names the root fallback"
    "j/k:select  Enter:open  Left:workspace root  Right:folder  g:directory  p:manifest  n:new TOML  PgUp/PgDn:details  Esc:cancel"
    (Browser.hints remembered);
  check bool "details name the root fallback" true
    (List.mem "No folder read yet. Left:workspace root · g:directory · p:manifest"
      (Browser.lines ~height:12 ~render:(fun s->[s]) remembered));
  check bool "an unread workspace root has nothing above it" true
    (match Browser.handle ~key:"left" (Browser.create ()) |> ok with Updated _ -> true | _ -> false)

let () = run "Local package discovery and selection" ["journeys",[
  test_case "discover actual directory with explicit loader outcomes" `Quick discover_workspace;
  test_case "never load manifests outside workspace" `Quick containment;
  test_case "folder to package selection and existing preview handoff" `Quick navigation;
  test_case "all entries reachable in a short terminal" `Quick reachable_large_list;
  test_case "an unread remembered folder still reaches the workspace root" `Quick unread_remembered_folder]]
