(* RFC-0481 §3.2: a roster row shows the Keeper's runtime id, so a runtime
   catalogue that moves a Keeper's route announces that row, and one that moves
   the default route announces every row. *)

open Alcotest
open Masc

module Broadcast = Server_runtime_assignment_broadcast

let runtime_toml ~default ~assignments =
  Printf.sprintf
    {|
[runtime]
default = "%s"

[runtime.assignments]
%s

[providers.p]
display-name = "P"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.m1]
api-name = "m1"
max-context = 8192
tools-support = true
streaming = true

[models.m2]
api-name = "m2"
max-context = 8192
tools-support = true
streaming = true

[p.m1]
is-default = true
max-concurrent = 1

[p.m2]
max-concurrent = 1
|}
    default
    (String.concat "\n"
       (List.map (fun (keeper, runtime) -> Printf.sprintf "%s = %S" keeper runtime) assignments))
;;

let load ~base_path ~default ~assignments =
  let path = Filename.concat base_path "runtime.toml" in
  Out_channel.with_open_bin path (fun oc ->
    output_string oc (runtime_toml ~default ~assignments));
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error error -> failf "runtime.toml did not load: %s" error
;;

let announcement = testable (fun ppf -> function
  | Broadcast.Every_row -> Format.pp_print_string ppf "every row"
  | Broadcast.Rows keepers -> Format.fprintf ppf "rows %s" (String.concat "," keepers))
  ( = )
;;

let test_announcement_names_moved_rows () =
  let routes default_route assignments = { Broadcast.default_route; assignments } in
  let before = routes "p.m1" [ "alpha", "p.m2"; "gamma", "p.m2" ] in
  check announcement "moved, added and dropped assignments are those rows"
    (Broadcast.Rows [ "alpha"; "beta"; "gamma" ])
    (Broadcast.announcement ~before
       ~after:(routes "p.m1" [ "alpha", "p.m1"; "beta", "p.m2" ]));
  check announcement "an unchanged catalogue moves no row" (Broadcast.Rows [])
    (Broadcast.announcement ~before ~after:before);
  check announcement "a moved default route is every row" Broadcast.Every_row
    (Broadcast.announcement ~before ~after:(routes "p.m2" before.assignments))
;;

let test_reloads_announce_moved_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "runtime-assignment-announce-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    load ~base_path ~default:"p.m1" ~assignments:[ "alpha", "p.m2" ];
    let heard = ref [] in
    let id = "runtime-assignment-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match
          Json_util.assoc_string_opt "type" event.ext_payload,
          Json_util.assoc_string_opt "name" event.ext_payload
        with
        | Some kind, Some name when String.equal kind Keeper_row_broadcast.row_changed_event ->
          heard := ("row", name) :: !heard
        | Some kind, None when String.equal kind Keeper_row_broadcast.roster_changed_event ->
          heard := ("roster", "") :: !heard
        | (Some _ | None), (Some _ | None) -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      Eio.Switch.run @@ fun sw ->
      Broadcast.install ~sw ~base_path;
      let settle () =
        for _ = 1 to 20 do Eio.Fiber.yield () done;
        let taken = List.rev !heard in
        heard := [];
        taken
      in
      let signals = list (pair string string) in
      load ~base_path ~default:"p.m1" ~assignments:[ "alpha", "p.m1"; "beta", "p.m2" ];
      check signals "a reload that moves two routes announces those rows"
        [ "row", "alpha"; "row", "beta" ] (settle ());
      load ~base_path ~default:"p.m1" ~assignments:[ "alpha", "p.m1"; "beta", "p.m2" ];
      check signals "a reload that moves nothing announces nothing" [] (settle ());
      load ~base_path ~default:"p.m2" ~assignments:[ "alpha", "p.m1"; "beta", "p.m2" ];
      check signals "a moved default route is a roster change" [ "roster", "" ] (settle ())))
;;

let () =
  run "runtime_assignment_announce"
    [ ( "announcement"
      , [ test_case "names the rows a catalogue moved" `Quick test_announcement_names_moved_rows ] )
    ; ( "reload"
      , [ test_case "reloads announce the moved rows" `Quick test_reloads_announce_moved_rows ] )
    ]
;;
