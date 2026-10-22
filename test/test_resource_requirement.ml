module R = Resource_requirement

let contains text fragment =
  let size = String.length fragment and limit = String.length text in
  let rec at index = index + size <= limit
    && (String.equal (String.sub text index size) fragment || at (index + 1)) in
  at 0

let names detail fragments = List.iter (fun fragment ->
  Alcotest.(check bool) (Printf.sprintf "%S names %S" detail fragment) true (contains detail fragment))
  fragments

let refused = function
  | Ok _ -> Alcotest.fail "the requirement admitted a path it must refuse"
  | Error detail -> detail

let admitted = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail

let with_directory perms work =
  let path = Unix.realpath (Filename.temp_dir ~perms:0o700 "resource-requirement-" "") in
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o700; Unix.rmdir path)
    (fun () -> Unix.chmod path perms; work path)

let remove_if_present path = try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let test_open_directory_is_refused () = with_directory 0o755 (fun path ->
  let detail = refused (R.lstat ~label:"Firefox profile" R.private_directory path) in
  names detail [path; "Firefox profile"; "0755"; "0700"])

let test_private_directory_is_admitted () = with_directory 0o700 (fun path ->
  let stats = admitted (R.lstat ~label:"Firefox profile" R.private_directory path) in
  Alcotest.(check bool) "returns the stats it decided" true (stats.Unix.st_kind = Unix.S_DIR))

let test_mask_rule_keeps_its_own_meaning () =
  let rule = { R.kind = Unix.S_DIR; mode = Clear 0o077; links = Any_count } in
  with_directory 0o750 (fun path ->
    names (refused (R.lstat ~label:"native claim root" rule path)) [path; "0750"; "0077"]);
  with_directory 0o500 (fun path -> ignore (admitted (R.lstat ~label:"native claim root" rule path)))

let test_second_link_is_refused () = with_directory 0o700 (fun directory ->
  let file = Filename.concat directory "lease" and alias = Filename.concat directory "alias" in
  Fun.protect ~finally:(fun () -> remove_if_present alias; remove_if_present file) (fun () ->
    Unix.close (Unix.openfile file [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600);
    Unix.chmod file 0o600;
    ignore (admitted (R.lstat ~label:"claim lease" R.private_file file));
    Unix.link file alias;
    names (refused (R.lstat ~label:"claim lease" R.private_file file)) [file; "exactly one link"; "2 links"]))

let test_key_set_refusal_lists_both_sets () =
  let detail = R.keys ~label:"owned Firefox configuration"
    ~found:["profile"; "port"; "extra"] ~required:["root"; "port"; "profile"] in
  names detail ["owned Firefox configuration"; "port, profile, root"; "extra, port, profile"]

let () =
  Alcotest.run "resource_requirement"
    [ "decisions",
      [ Alcotest.test_case "a 0755 directory is refused with path and modes" `Quick test_open_directory_is_refused;
        Alcotest.test_case "a 0700 directory is admitted" `Quick test_private_directory_is_admitted;
        Alcotest.test_case "a mask rule refuses group bits and admits 0500" `Quick test_mask_rule_keeps_its_own_meaning;
        Alcotest.test_case "a second hard link is refused" `Quick test_second_link_is_refused;
        Alcotest.test_case "a key-set refusal lists found and required keys" `Quick test_key_set_refusal_lists_both_sets ] ]
