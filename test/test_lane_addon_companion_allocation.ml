(** Actual allocation/broker lifecycle fixtures. Parse-only does not execute
    these scenarios or prove listener, cancellation or cleanup behavior. *)
open Alcotest
open Masc
module A = Lane_addon_companion_allocation
module B = Lane_addon_companion_broker

exception Stop_owner

let ok = function Ok value -> value | Error _ -> fail "private allocation fixture failed"
let exists path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false

let unlink_if_present path =
  try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_root run =
  let root = Filename.temp_dir "ca-" "" |> Unix.realpath in
  let previous = Filename.get_temp_dir_name () in
  Fun.protect ~finally:(fun () ->
    Filename.set_temp_dir_name previous;
    Fs_compat.remove_tree root) (fun () ->
    Filename.set_temp_dir_name root;
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () -> run root env)))

let socket_path owned =
  let grant = B.issue (A.broker owned) ~publish:None ~bind:(fun _ -> Error B.Not_started) |> ok in
  let path = Yojson.Safe.Util.(B.descriptor grant |> member "socket_path" |> to_string) in
  B.end_invocation grant;
  path

let with_allocation run = with_temp_root (fun root env ->
  Eio.Switch.run (fun sw ->
    let owned = A.create ~sw ~max_message_bytes:16384 |> ok in
    run root env sw owned (socket_path owned)))

let cancelled_entry_allocates_nothing () = with_temp_root (fun root _ ->
  Eio.Switch.run (fun sw ->
    let cancelled = ref false in
    Eio.Cancel.sub (fun context ->
      Eio.Cancel.cancel context Stop_owner;
      (match A.create ~sw ~max_message_bytes:16384 with
       | Ok _ | Error _ -> fail "cancelled allocation entry must propagate cancellation"
       | exception Eio.Cancel.Cancelled _ -> cancelled := true));
    check bool "allocation propagates the cancelled caller" true !cancelled;
    check int "no protected allocation escapes before startup installs its guard" 0
      (Array.length (Sys.readdir root))))

let failed_startup_reports_retained_directory () = with_temp_root (fun root _ ->
  Eio.Switch.run (fun sw ->
    check bool "listener startup refuses an invalid message limit" true
      (A.create ~sw ~max_message_bytes:0 = Error A.Cleanup_unconfirmed);
    check int "startup refuses after joining resources and retaining its path" 1
      (Array.length (Sys.readdir root))))

let cleanup_joins_exact_settlement () = with_allocation (fun _ _ sw owned path ->
  let entered, enter = Eio.Promise.create () in
  let allowed, allow = Eio.Promise.create () in
  let completions = ref [] in
  let notify = A.on_finish owned (fun completion ->
    completions := completion :: !completions;
    Eio.Promise.resolve enter ();
    Eio.Promise.await allowed;
    Ok ()) |> ok in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow ())) (fun () ->
    notify B.Released;
    Eio.Promise.await entered;
    let cleaning = Eio.Fiber.fork_promise ~sw (fun () -> A.cleanup owned) in
    Eio.Fiber.yield ();
    check bool "cleanup does not claim Browser settlement before it returns" false
      (Eio.Promise.is_resolved cleaning);
    Eio.Promise.resolve allow ();
    check bool "joined settlement and original IPC cleanup are confirmed" true
      (Eio.Promise.await_exn cleaning = Ok (A.Paths_retained (Filename.dirname path)));
    notify B.Abandoned;
    check bool "only the first exact notification runs settlement" true (!completions = [B.Released]);
    check bool "stopped original socket and directory remain retained" true (exists path);
    let connection = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close connection) (fun () ->
      check bool "retained socket no longer accepts connections" true
        (match Unix.connect connection (Unix.ADDR_UNIX path) with
         | () -> false
         | exception Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> true));
    check bool "cleanup retains its original successful result" true (A.cleanup owned = Ok (A.Paths_retained (Filename.dirname path)));
    check bool "new settlement cannot register after retirement" true
      (A.on_finish owned (fun _ -> fail "retired callback ran") = Error "private companion is retiring")))

let unnotified_settlement_is_abandoned () = with_allocation (fun _ _ _ owned path ->
  let completions = ref [] in
  let (_notify : B.completion -> unit) =
    A.on_finish owned (fun completion -> completions := completion :: !completions; Ok ()) |> ok in
  check bool "unused settlement registration does not strand cleanup" true
    (A.cleanup owned = Ok (A.Paths_retained (Filename.dirname path)));
  check bool "missing broker notification is abandonment, never release" true (!completions = [B.Abandoned]))

let cancelled_owner_retains_unknown_settlement () = with_temp_root (fun root _ ->
  let retained = ref None and calls = ref 0 in
  (match Eio.Switch.run (fun sw ->
     let owned = A.create ~sw ~max_message_bytes:16384 |> ok in
     retained := Some owned;
     let (_notify : B.completion -> unit) = A.on_finish owned (fun _ -> incr calls; Ok ()) |> ok in
     Eio.Switch.fail sw Stop_owner)
   with
   | () -> fail "owner cancellation must remain visible"
   | exception Stop_owner -> ());
  let owned = match !retained with Some owned -> owned | None -> fail "no original allocation retained" in
  check int "settlement was never invoked without its completion" 0 !calls;
  check bool "a cancelled settlement is not a successful join" true (Result.is_error (A.cleanup owned));
  check int "unknown Browser settlement retains the stopped IPC path" 1
    (Array.length (Sys.readdir root)))

let callback_failures_are_fixed () =
  List.iter (fun raises -> with_allocation (fun _ _ _ owned _ ->
    let notify = A.on_finish owned (fun _ ->
      if raises then failwith "PRIVATE_SETTLEMENT_MARKER" else Error "PRIVATE_SETTLEMENT_MARKER") |> ok in
    notify B.Released;
    check bool "callback prose never leaves the settlement boundary" true
      (A.cleanup owned = Error "private settlement unconfirmed");
    check bool "unconfirmed cleanup is retained without replay" true
      (A.cleanup owned = Error "private settlement unconfirmed"))) [false; true]

let replaced_directory_is_retained () = with_allocation (fun _ _ _ owned path ->
  let directory = Filename.dirname path in
  let original = directory ^ "-original" in
  let marker = Filename.concat directory "successor-marker" in
  Unix.rename directory original;
  Unix.mkdir directory 0o700;
  let channel = open_out marker in close_out channel;
  Fun.protect ~finally:(fun () ->
    unlink_if_present marker;
    Unix.rmdir directory;
    unlink_if_present (Filename.concat original "s");
    Unix.rmdir original) (fun () ->
    check bool "confirmed resource cleanup retains the original directory name" true
      (A.cleanup owned = Ok (A.Paths_retained directory));
    check bool "successor contents remain untouched" true (exists marker);
    check bool "the renamed original directory remains retained" true (exists original)))

let replaced_socket_is_retained () = with_allocation (fun _ _ _ owned path ->
  let directory = Filename.dirname path in
  let original = Filename.concat directory "original-socket" in
  Unix.rename path original;
  let replacement = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () ->
    Unix.close replacement;
    unlink_if_present path;
    unlink_if_present original;
    Unix.rmdir directory) (fun () ->
    Unix.bind replacement (Unix.ADDR_UNIX path);
    let identity = Unix.lstat path in
    check bool "confirmed resource cleanup retains the socket name" true
      (A.cleanup owned = Ok (A.Paths_retained directory));
    let current = Unix.lstat path in
    check bool "successor socket inode remains untouched" true
      (current.st_dev = identity.st_dev && current.st_ino = identity.st_ino)))

let () = run "private companion allocation" ["ownership", [
  test_case "cancelled entry cannot leak protected allocation" `Quick cancelled_entry_allocates_nothing;
  test_case "failed startup joins resources and reports retained directory" `Quick failed_startup_reports_retained_directory;
  test_case "cleanup joins exact notified settlement" `Quick cleanup_joins_exact_settlement;
  test_case "unused settlement is abandoned during cleanup" `Quick unnotified_settlement_is_abandoned;
  test_case "cancelled owner retains unknown settlement without deadlock" `Quick cancelled_owner_retains_unknown_settlement;
  test_case "callback errors and exceptions are fixed" `Quick callback_failures_are_fixed;
  test_case "successor directory is retained" `Quick replaced_directory_is_retained;
  test_case "successor socket is retained" `Quick replaced_socket_is_retained;
]]
