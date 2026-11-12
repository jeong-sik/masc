open Alcotest
module N = Native_file_change

let require = function Ok value -> value | Error error -> fail (N.error_to_string error)
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let target kind path =
  let status = Unix.stat path in
  { N.path; kind; device = status.st_dev; inode = status.st_ino }

let fixture f =
  Eio_main.run (fun env ->
    let root = Filename.temp_dir "native-file-change-" "" in
    let rec cleanup path =
      match (Unix.lstat path).st_kind with
      | Unix.S_DIR -> Sys.readdir path |> Array.iter (fun name -> cleanup (Filename.concat path name)); Unix.rmdir path
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
    in
    Fun.protect ~finally:(fun () -> cleanup root) (fun () ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () -> f env root)))

let changed watcher path =
  match N.await watcher |> require with
  | N.Changed targets -> check bool "the actual file is named" true (List.exists (fun t -> t.N.path = path) targets)
  | N.Coverage_lost _ -> fail "in-place write lost watch coverage"

let test_inplace_same_fingerprint () = fixture (fun _env root ->
  let path = Filename.concat root "source" in
  write path "old\n";
  Eio.Switch.run (fun sw ->
    let watcher = N.create ~sw ~targets:[target N.File path] |> require in
    let before = Unix.stat path in
    write path "new\n";
    Unix.utimes path before.st_atime before.st_mtime;
    changed watcher path))

let test_atomic_replace_new_generation () = fixture (fun _env root ->
  let path = Filename.concat root "source" and replacement = Filename.concat root "replacement" in
  write path "old\n";
  Eio.Switch.run (fun sw ->
    let old = N.create ~sw ~targets:[target N.File path; target N.Directory root] |> require in
    write replacement "new\n";
    Unix.rename replacement path;
    let rec lost () = match N.await old |> require with
      | N.Coverage_lost _ -> () | N.Changed _ -> lost () in
    lost ();
    let fresh = N.create ~sw ~targets:[target N.File path; target N.Directory root] |> require in
    N.close old;
    write path "current\n";
    changed fresh path))

let test_opened_inode_fence () = fixture (fun _env root ->
  let path = Filename.concat root "source" and replacement = Filename.concat root "replacement" in
  write path "old";
  let previous = target N.File path in
  write replacement "new";
  Unix.rename replacement path;
  Eio.Switch.run (fun sw ->
    match N.create ~sw ~targets:[previous] with
    | Error N.Target_changed -> ()
    | Error ((N.Unsupported_platform | N.System_error _ | N.Ambiguous_watch_identity | N.Closed) as error) ->
      fail (N.error_to_string error)
    | Ok watcher -> N.close watcher; fail "a different inode was registered silently"))

let test_directory_permissions () = fixture (fun _env root ->
  let path = Filename.concat root "source" in
  write path "retained";
  Eio.Switch.run (fun sw ->
    let watcher = N.create ~sw ~targets:[target N.Directory root] |> require in
    Fun.protect ~finally:(fun () -> Unix.chmod root 0o700) (fun () ->
      Unix.chmod root 0o500;
      (match N.await watcher |> require with
      | N.Changed targets ->
        check bool "directory permission change names its directory" true
          (List.exists (fun t -> t.N.path = root && t.N.kind = N.Directory) targets)
      | N.Coverage_lost _ -> fail "directory chmod lost watch coverage");
      let current = target N.Directory root in
      check int "reinventoried permissions reflect chmod" 0o500 (Unix.stat root).st_perm;
      check bool "directory can be reinventoried after the hint" true
        (current.N.path = root && Array.to_list (Sys.readdir root) = ["source"]))))

let test_cancel_then_close () = fixture (fun env root ->
  let path = Filename.concat root "source" in write path "idle";
  Eio.Switch.run (fun sw ->
    let watcher = N.create ~sw ~targets:[target N.File path] |> require in
    let cancelled = ref false in
    Eio.Fiber.first
      (fun () -> match N.await watcher with
        | _ -> fail "idle watcher woke"
        | exception (Eio.Cancel.Cancelled _ as exn) -> cancelled := true; raise exn)
      (fun () -> Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.01);
    check bool "pending readiness observed cancellation" true !cancelled;
    N.close watcher;
    N.close watcher;
    check bool "closed watcher cannot read a recycled descriptor" true (N.drain watcher = Error N.Closed)))

let () = run "native_file_change" [ "kernel", [
  test_case "in-place write with equal size and mtime" `Quick test_inplace_same_fingerprint;
  test_case "atomic replace uses a new native generation" `Quick test_atomic_replace_new_generation;
  test_case "opened inode matches inventory authority" `Quick test_opened_inode_fence;
  test_case "directory permissions wake reinventory" `Quick test_directory_permissions;
  test_case "pending readiness cancellation and close" `Quick test_cancel_then_close;
] ]
