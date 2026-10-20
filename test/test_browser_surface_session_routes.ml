(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

(* Dashboard workflows require their Add-on; installed builtin executors are
   never an implicit replacement. The independent Stagehand attach wait remains
   covered until owned backends move into the worker. *)
open Alcotest
module Lane = Browser_lane
module Routes = Server_routes_http_browser_surface

let answered = Lane.Answered (`Assoc [ "ok", `Bool true; "data", `Assoc [] ])

let with_executors f =
  Eio_main.run
  @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let automation = ref [] and stagehand = ref [] in
  Lane.install_automation_executor (Some (fun verb -> automation := verb :: !automation; answered));
  Lane.install_stagehand_executor (Some (fun ~actor:_ verb -> stagehand := verb :: !stagehand; answered));
  Fun.protect
    ~finally:(fun () ->
      Lane.install_automation_executor None;
      Lane.install_stagehand_executor None)
    (fun () -> f ~automation ~stagehand)
;;

let body fields = `Assoc fields

let test_missing_addon_does_not_use_builtin_executors () =
  let root=Filename.temp_dir "browser-view-routes-" "" in
  let rec remove path=match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
    | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    with_executors (fun ~automation ~stagehand ->
      let config=Masc.Workspace.default_config root in
      let execute operation fields=Routes.view ~config
        ~principal:(Lane_addon_call_context.Host_actor "dashboard-tester") operation (body fields) in
      let results=[
        execute Masc.Browser_addon_view.session ["action",`String "open";"lane",`String "stagehand"];
        execute Masc.Browser_addon_view.goto ["url",`String "https://example.org/";"lane",`String "automation"]] in
      List.iter (fun result -> check bool "missing Add-on is unavailable" true
        (Tool_result.failure_class result=Some Tool_result.Dependency_unavailable)) results;
      check int "neither builtin executor receives input" 0 (List.length !automation+List.length !stagehand)))
;;

let test_stagehand_open_waits_for_attach () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Lane.install_stagehand_executor
    (Some (fun ~actor:_ _ ->
       Eio.Time.sleep clock 0.01;
       answered));
  Fun.protect
    ~finally:(fun () -> Lane.install_stagehand_executor None)
    (fun () ->
      check bool "generic deadline does not abandon a Stagehand open" true
        (Lane.issue_server_lane Lane.Server_stagehand
           ~verb:(Lane.Session_open { headless = None }) ~timeout_sec:0.0 = answered))
;;

let () =
  run "browser_surface_session_routes" [
    "lanes", [
      test_case "missing Add-on never borrows builtin executors" `Quick test_missing_addon_does_not_use_builtin_executors;
      test_case "Stagehand open keeps its attach wait" `Quick test_stagehand_open_waits_for_attach;
    ];
  ]
;;
