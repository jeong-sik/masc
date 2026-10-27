(* [Workspace.default_config] builds a config on a cache miss while it holds the
   cache lock. The build stats the filesystem through Eio, which suspends the
   calling fiber, and every fiber of a domain shares one thread. A lock that
   raises when the thread that holds it locks it again therefore fails the next
   caller instead of making it wait. At server boot the maintenance pass asked
   for the config of one base path once per Keeper while the first build was
   still stat-ing, and each of the 41 calls raised
   Sys_error "Mutex.lock: Resource deadlock avoided". *)
open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(* Both base paths start cold: the cache is emptied before the scheduler runs
   and the Eio filesystem is installed, so a build has to stat through Eio. *)
let with_cold_cache f =
  let first = Filename.temp_dir "default-config-cold-first-" "" in
  let second = Filename.temp_dir "default-config-cold-second-" "" in
  Fun.protect
    ~finally:(fun () ->
      Workspace.reset_default_config_cache ();
      rm_rf first;
      rm_rf second)
    (fun () ->
      Workspace.reset_default_config_cache ();
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~first ~second)))

let test_waiters_share_the_first_build () =
  with_cold_cache (fun ~first ~second:_ ->
    let callers = 8 in
    let asked = ref 0 in
    let asked_when_served = ref [] in
    let ask _ =
      incr asked;
      let config = Workspace.default_config first in
      asked_when_served := !asked :: !asked_when_served;
      config
    in
    let configs = Eio.Fiber.List.map ask (List.init callers Fun.id) in
    (* The first build suspends inside the lock, so every other caller has
       asked before any caller is served. A build that never suspended would
       serve the first caller after one ask and the test would prove nothing. *)
    check (list int) "every caller asked before any was served"
      (List.init callers (fun _ -> callers)) !asked_when_served;
    match configs with
    | [] -> fail "no caller returned"
    | config :: others ->
      List.iter
        (fun other -> check bool "one cached config" true (other == config))
        others)

let test_other_base_path_waits_instead_of_raising () =
  with_cold_cache (fun ~first ~second ->
    let configs = Eio.Fiber.List.map Workspace.default_config [ first; second ] in
    List.iter2
      (fun path config ->
        check string "config belongs to the base path it was asked for" path
          config.Workspace.workspace_path)
      [ first; second ] configs)

let () =
  run "workspace default_config concurrent"
    [ ( "cold cache"
      , [ test_case "waiters share the first build" `Quick
            test_waiters_share_the_first_build
        ; test_case "another base path waits instead of raising" `Quick
            test_other_base_path_waits_instead_of_raising
        ] )
    ]
