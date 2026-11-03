(* RFC-0481 §3.2: every runtime catalogue publication tells the workspace's
   roster readers that every row may have moved. The fiber starts before any
   runtime is loaded, as the server bootstrap installs it. *)

open Alcotest
open Masc

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

(* Long enough for the daemon to wake on an idle machine; a signal that does
   not come in this time is reported as missing. *)
let signal_wait_s = 5.0

let test_each_publication_announces_every_row () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  let base_path = Filename.temp_dir "runtime-assignment-announce-" "" in
  let original = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore original;
      Fs_compat.remove_tree base_path)
    (fun () ->
      let heard = Eio.Stream.create max_int in
      let id = "runtime-assignment-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match Json_util.assoc_string_opt "type" event.ext_payload with
          | Some kind when String.equal kind Keeper_row_broadcast.roster_changed_event ->
            Eio.Stream.add heard ()
          | Some _ | None -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        Eio.Switch.run @@ fun sw ->
        Server_runtime_assignment_broadcast.install ~sw ~base_path;
        let expect_roster_change label =
          match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok () -> ()
          | Error `Timeout -> failf "%s: no roster change" label
        in
        load ~base_path ~default:"p.m1" ~assignments:[ "alpha", "p.m2" ];
        expect_roster_change "the first load, with nothing loaded before it";
        load ~base_path ~default:"p.m1" ~assignments:[ "alpha", "p.m2" ];
        expect_roster_change "a reload with the same routes, since lane walks may move";
        Runtime.enter_setup_required ~reason:Runtime_startup_state.Config_missing ();
        expect_roster_change "entering setup-required";
        load ~base_path ~default:"p.m2" ~assignments:[];
        expect_roster_change "a load after setup-required, so the fiber outlived it";
        check int "one signal per publication" 0 (Eio.Stream.length heard)))
;;

let () =
  run "runtime_assignment_announce"
    [ ( "publication"
      , [ test_case "each publication announces every row" `Quick
            test_each_publication_announces_every_row ] )
    ]
;;
