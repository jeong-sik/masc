let checks = ref 0
let check label condition = incr checks; if not condition then failwith label
let cases = ref []
let case label = cases := label :: !cases

let rec remove_tree path =
  match Unix.lstat path with
  | {Unix.st_kind = Unix.S_DIR; _} ->
    Array.iter (fun leaf -> remove_tree (Filename.concat path leaf)) (Sys.readdir path);
    Unix.rmdir path
  | {Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
                    | Unix.S_FIFO | Unix.S_SOCK); _} -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root f =
  let root = Filename.temp_dir "kind-fixture-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let write path = Out_channel.with_open_bin path (fun out -> output_string out "fixture")

let before ?(follow = true) path =
  match Before.exact_path_kind ~follow path with
  | Before.Exact_missing -> `Missing
  | Before.Exact_kind kind -> `Kind kind
  | Before.Exact_unknown -> `Unknown

let after ?(follow = true) path =
  match After.exact_path_kind ~follow path with
  | After.Exact_missing -> `Missing
  | After.Exact_kind kind -> `Kind kind
  | After.Exact_unknown -> `Unknown

let observe f =
  match f () with
  | value -> Ok value
  | exception Sys_error message -> Error message

type behavior =
  | Native
  | Kind of Eio.File.Stat.kind
  | Kind_at_path of string * Eio.File.Stat.kind
  | Raise_at_path of string * exn
  | Raised of exn
  | Await_cancel of unit Eio.Promise.u

type counts =
  { mutable stats : int
  ; mutable formats : int
  ; mutable arguments : (bool * string) list
  ; mutable format_trace : Printexc.raw_backtrace option
  }

let[@inline never] raise_from_provider exn = raise exn

let wrap (Eio.Resource.T (dir, ops), prefix) template behavior =
  let module Real = (val Eio.Resource.get ops Eio.Fs.Pi.Dir) in
  let counts = {stats = 0; formats = 0; arguments = []; format_trace = None} in
  let module Observed = struct
    include Real
    let stat dir ~follow path =
      counts.stats <- counts.stats + 1;
      counts.arguments <- (follow, path) :: counts.arguments;
      match behavior with
      | Native -> Real.stat dir ~follow path
      | Kind kind -> {template with Eio.File.Stat.kind}
      | Kind_at_path (target, kind) ->
        if String.equal path target then {template with Eio.File.Stat.kind}
        else Real.stat dir ~follow path
      | Raise_at_path (target, exn) ->
        if String.equal path target then raise_from_provider exn
        else Real.stat dir ~follow path
      | Raised exn -> raise_from_provider exn
      | Await_cancel started ->
        Eio.Promise.resolve started ();
        Eio.Fiber.await_cancel ()
    let pp fmt dir =
      counts.formats <- counts.formats + 1;
      counts.format_trace <- Some (Printexc.get_raw_backtrace ());
      Real.pp fmt dir
  end in
  let fs : Eio.Fs.dir_ty Eio.Path.t =
    Eio.Resource.T (dir, Eio.Resource.handler
      [Eio.Resource.H (Eio.Fs.Pi.Dir, (module Observed))]), prefix
  in
  fs, counts

let expected_kind : Eio.File.Stat.kind -> _ = function
  | `Unknown -> `Unknown
  | `Directory -> `Kind Unix.S_DIR
  | `Regular_file -> `Kind Unix.S_REG
  | `Symbolic_link -> `Kind Unix.S_LNK
  | `Fifo -> `Kind Unix.S_FIFO
  | `Character_special -> `Kind Unix.S_CHR
  | `Block_device -> `Kind Unix.S_BLK
  | `Socket -> `Kind Unix.S_SOCK

let first_slot_name = function
  | None -> None
  | Some trace ->
    match Printexc.backtrace_slots trace with
    | Some slots when Array.length slots > 0 -> Printexc.Slot.name slots.(0)
    | Some _ | None -> None

let compare_real ~fs paths =
  Ports.set_fs fs;
  List.iter (fun follow -> List.iter (fun path ->
    check "actual filesystem outcomes agree"
      (observe (fun () -> before ~follow path) = observe (fun () -> after ~follow path))) paths)
    [false; true]

let fixture_kinds fs template =
  let directory, _ = fs in
  let virtual_fs = directory, "capability-prefix" in
  List.iter (fun kind -> List.iter (fun follow ->
    let a, ca = wrap virtual_fs template (Kind kind) in
    Ports.set_fs a;
    let ra = before ~follow "virtual-only" in
    let b, cb = wrap virtual_fs template (Kind kind) in
    Ports.set_fs b;
    let rb = after ~follow "virtual-only" in
    check "all supplied provider kinds preserved" (ra = expected_kind kind && ra = rb);
    check "one stat per kind observation" (ca.stats = 1 && cb.stats = 1);
    check "follow and capability-relative leaf preserved"
      (ca.arguments = [follow, "capability-prefix/virtual-only"] && ca.arguments = cb.arguments);
    check "successful and unknown kinds never format context" (ca.formats = 0 && cb.formats = 0))
    [false; true])
    [`Unknown; `Directory; `Regular_file; `Symbolic_link; `Fifo;
     `Character_special; `Block_device; `Socket];
  case "all eight provider kinds, both follow flags, virtual capability namespace"

let fixture_errors fs template path =
  let backend code = Eio_unix.Unix_error (code, "fixture-stat", "fixture-leaf") in
  let missing = Eio.Fs.err (Not_found (backend Unix.ENOENT))
    |> fun exn -> Eio.Exn.add_context exn "existing provider context" in
  let a, ca = wrap fs template (Raised missing) in
  Ports.set_fs a;
  let ra = before path in
  let b, cb = wrap fs template (Raised missing) in
  Ports.set_fs b;
  check "handled Not_found remains missing" (ra = `Missing && after path = `Missing);
  check "Not_found uses exactly one stat" (ca.stats = 1 && cb.stats = 1);
  check "only discarded formatting is removed" (ca.formats = 1 && cb.formats = 0);
  let denied = Eio.Fs.err (Permission_denied (backend Unix.EACCES))
    |> fun exn -> Eio.Exn.add_context exn "existing provider context" in
  let a, ca = wrap fs template (Raised denied) in
  Ports.set_fs a;
  let ra = observe (fun () -> before path) in
  let b, cb = wrap fs template (Raised denied) in
  Ports.set_fs b;
  let rb = observe (fun () -> after path) in
  check "nonmissing full rendered Sys_error identical" (ra = rb && Result.is_error ra);
  check "nonmissing error stats and context counts identical"
    (ca.stats = 1 && cb.stats = 1 && ca.formats = 1 && cb.formats = 1);
  check "backend raise origin survives context rethrow"
    (first_slot_name ca.format_trace = Some "Probe.raise_from_provider"
     && first_slot_name ca.format_trace = first_slot_name cb.format_trace);
  List.iter (fun exn ->
    List.iter (fun f ->
      let wrapped, counts = wrap fs template (Raised exn) in
      Ports.set_fs wrapped;
      let escaped = try ignore (f path); false with caught -> caught == exn in
      check "non-I/O exception object escapes unchanged" escaped;
      check "non-I/O exception adds no context" (counts.stats = 1 && counts.formats = 0))
      [before; after]) [Exit; Eio.Cancel.Cancelled Exit];
  case "Not_found, existing context, nonmissing error text and backend backtrace origin";
  case "non-I/O and explicit cancellation exceptions retain identity"

let fixture_cancellation fs template path =
  List.iter (fun f ->
    let started, notify = Eio.Promise.create () in
    let wrapped, counts = wrap fs template (Await_cancel notify) in
    Ports.set_fs wrapped;
    let cancelled = ref false in
    Eio.Fiber.first
      (fun () ->
        try ignore (f path); failwith "cancelled stat returned" with
        | Eio.Cancel.Cancelled _ as exn -> cancelled := true; raise exn)
      (fun () -> Eio.Promise.await started);
    check "actual fiber cancellation reaches stat caller" !cancelled;
    check "cancelled stat is not formatted or retried" (counts.stats = 1 && counts.formats = 0))
    [before; after];
  case "real fiber cancellation while supplied stat is suspended"

let fixture_freshness fs path =
  List.iter (fun f ->
    Ports.set_fs fs;
    check "initially missing" (f path = `Missing);
    write path;
    check "new publication visible next call" (f path = `Kind Unix.S_REG);
    Unix.unlink path;
    check "removal visible next call" (f path = `Missing)) [before; after];
  case "fresh missing-to-created-to-deleted observations"

let fixture_discovery fs template base =
  let queue = Filename.concat base "queue-inventory" in
  Unix.mkdir queue 0o700;
  let owner name leaf =
    let path = Filename.concat queue name in
    Unix.mkdir path 0o700;
    Filename.concat path leaf
  in
  write (owner "snapshot" Discovery_after.snapshot_filename);
  write (owner "wal" Discovery_after.transition_wal_filename);
  write (owner "intent" Discovery_after.Quarantine.filename);
  Unix.symlink "absent-target" (owner "dangling" Discovery_after.snapshot_filename);
  ignore (owner "empty" "absent");
  Unix.symlink "loop" (Filename.concat queue "loop");
  Ports.set_fs fs;
  let a = Discovery_before.discover_keeper_names_with_durable_state ~base_path:queue in
  let b = Discovery_after.discover_keeper_names_with_durable_state ~base_path:queue in
  check "external snapshot/WAL/intent/dangling entries remain discoverable"
    (b.keeper_names = ["dangling"; "intent"; "snapshot"; "wal"]);
  check "discovery names and complete error text agree"
    (a.keeper_names = b.keeper_names && a.read_error = b.read_error);
  check "uninspectable sibling remains explicit alongside healthy names" (Option.is_some b.read_error);
  let mixed = owner "mixed" Discovery_after.snapshot_filename in
  write mixed;
  let mixed_wal = Filename.concat (Filename.dirname mixed) Discovery_after.transition_wal_filename in
  let mixed_intent = Discovery_after.Quarantine.path ~snapshot:mixed in
  let denied = Eio.Fs.err (Permission_denied (Eio_unix.Unix_error
      (Unix.EACCES, "fixture-stat", "fixture-leaf"))) in
  List.iter (fun behavior ->
    let a_fs, ca = wrap fs template behavior in
    Ports.set_fs a_fs;
    let a = Discovery_before.discover_keeper_names_with_durable_state ~base_path:queue in
    let b_fs, cb = wrap fs template behavior in
    Ports.set_fs b_fs;
    let b = Discovery_after.discover_keeper_names_with_durable_state ~base_path:queue in
    check "a present primary does not hide unreadable or unknown siblings"
      (not (List.mem "mixed" b.keeper_names) && Option.is_some b.read_error);
    check "partial failure result and inspection order preserved"
      (a.keeper_names = b.keeper_names && a.read_error = b.read_error
       && ca.arguments = cb.arguments))
    [Kind_at_path (mixed_wal, `Unknown); Raise_at_path (mixed_wal, denied);
     Raise_at_path (mixed_intent, denied)];
  case "actual discovery body retains WAL-only, intent-only, dangling and partial failures";
  case "present primary cannot hide unknown WAL or denied WAL/quarantine inspection"

let measure ~version ~scenario ~round ~iterations f paths =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let start_cpu = Unix.times () and start_wall = Unix.gettimeofday () in
  for _ = 1 to iterations do List.iter f paths done;
  let elapsed_wall = Unix.gettimeofday () -. start_wall and end_cpu = Unix.times () in
  let bytes = Gc.allocated_bytes () -. allocated in
  `Assoc ["version", `String version; "scenario", `String scenario; "round", `Int round;
          "adapter_calls", `Int (iterations * List.length paths); "allocated_bytes", `Float bytes;
          "cpu_seconds", `Float (end_cpu.Unix.tms_utime +. end_cpu.Unix.tms_stime
             -. start_cpu.Unix.tms_utime -. start_cpu.Unix.tms_stime);
          "wall_seconds", `Float elapsed_wall]

let run ~iterations native_test =
  Printexc.record_backtrace true;
  with_root @@ fun root ->
  let regular = Filename.concat root "regular" in
  write regular;
  Ports.clear_fs ();
  check "fallback missing stays typed" (before (regular ^ "/child") = `Unknown
    && after (regular ^ "/child") = `Unknown);
  case "unchanged non-Eio Unix fallback for ENOTDIR";
  let measurements = Eio_main.run @@ fun env ->
    let fs = Eio.Stdenv.fs env in
    let directory = Filename.concat root "directory" and fifo = Filename.concat root "fifo"
    and socket_path = Filename.concat root "socket" and link = Filename.concat root "link"
    and dangling = Filename.concat root "dangling" and loop = Filename.concat root "loop" in
    Unix.mkdir directory 0o700;
    Unix.mkfifo fifo 0o600;
    let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
    Unix.bind socket (Unix.ADDR_UNIX socket_path);
    Unix.symlink "regular" link; Unix.symlink "absent" dangling; Unix.symlink "loop" loop;
    let missing = Filename.concat root "missing" in
    compare_real ~fs [regular; directory; fifo; socket_path; link; dangling; loop;
                      missing; Filename.concat missing "child"; Filename.concat regular "child"];
    case "real Eio regular/directory/FIFO/socket/links/missing/ENOTDIR, both follow flags";
    if Unix.geteuid () = 0 then case "parent-permission fixture skipped for root" else (
      Unix.chmod directory 0o000;
      Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
        let denied = Filename.concat directory "child" in
        check "parent fixture actually denies inspection"
          (match Unix.lstat denied with
           | _ -> false
           | exception Unix.Unix_error (Unix.EACCES, _, _) -> true);
        compare_real ~fs [denied];
        check "denied path remains an error" (Result.is_error (observe (fun () -> after denied))));
      case "real Eio denied parent remains an error");
    let template = Eio.Path.stat ~follow:false Eio.Path.(fs / regular) in
    fixture_kinds fs template;
    fixture_errors fs template missing;
    fixture_cancellation fs template missing;
    fixture_freshness fs (Filename.concat root "fresh");
    fixture_discovery fs template root;
    let wrapped, counts = wrap fs template (Kind `Directory) in
    Ports.set_fs wrapped;
    Eio_unix.run_in_systhread (fun () ->
      check "systhread uses unchanged Unix fallback" (before missing = `Missing && after missing = `Missing));
    check "systhread does not enter supplied Eio provider" (counts.stats = 0);
    case "non-Eio systhread fallback with global filesystem installed";
    Ports.set_fs fs;
    native_test ~fs ();
    case "exact new native regression body executed (temporary-directory owner supplied)";
    let missing_paths = List.map (Filename.concat root)
        [Discovery_after.snapshot_filename; Discovery_after.transition_wal_filename;
         Discovery_after.Quarantine.filename] in
    let a path = ignore (Before.exact_path_kind ~follow:false path) in
    let b path = ignore (After.exact_path_kind ~follow:false path) in
    List.concat_map (fun round ->
      List.concat_map (fun (scenario, paths) ->
        let order = if round mod 2 = 1 then ["before", a; "after", b] else ["after", b; "before", a] in
        List.map (fun (version, f) -> measure ~version ~scenario ~round ~iterations f paths) order)
        ["missing", missing_paths; "present", [regular; directory; link]]) [1; 2; 3])
  in
  Printf.printf "%s\n" (Yojson.Safe.pretty_to_string (`Assoc
    ["checks", `Int !checks; "cases", `List (List.rev_map (fun s -> `String s) !cases);
     "iterations_per_path", `Int iterations; "measurements", `List measurements;
     "scope", `String "actual source-extracted adapters/ports/execution context and real Eio; discovery canonical-base, directory-layout and name-parser ports synthetic; no product runtime"]));
  Ports.clear_fs ()
