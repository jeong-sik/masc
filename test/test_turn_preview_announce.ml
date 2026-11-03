(* RFC-0481 §3.5: a write to the preview a Keeper's turns answer shows tells
   that workspace's turns readers, at most once per interval for a burst. *)

open Alcotest
open Masc

(* Long enough for the fiber to wake on an idle machine. *)
let signal_wait_s = 5.0

(* Several intervals: a second send for one burst would land inside it. *)
let quiet_wait_s = Server_turn_preview_broadcast.post_interval_s *. 4.0

let ignore_writes ~base_path:_ ~keeper_name:_ = ()

let reset ~base_path keeper_name =
  Keeper_turn_preview.reset ~base_path ~keeper_name ~execution_scope:None ~turn_ref:None
    ~now:(Unix.gettimeofday ()) ~redaction:Keeper_secret_redaction.empty
;;

let note_tool writer tool = Keeper_turn_preview.note_tool ~writer:(Some writer) ~now:(Unix.gettimeofday ()) tool

let test_only_the_shown_writer_reports () =
  let heard = ref [] in
  Keeper_turn_preview_signal.install (fun ~base_path ~keeper_name ->
    heard := (base_path, keeper_name) :: !heard);
  Fun.protect ~finally:(fun () -> Keeper_turn_preview_signal.install ignore_writes) (fun () ->
    let base_path = "turn-preview-announce" in
    let first = reset ~base_path "alpha" in
    check int "installing a preview reports it" 1 (List.length !heard);
    note_tool first "read_file";
    check int "a note on the shown preview reports it" 2 (List.length !heard);
    let second = reset ~base_path "alpha" in
    check int "a newer preview reports itself" 3 (List.length !heard);
    note_tool first "write_file";
    check int "a note on the older preview reports nothing" 3 (List.length !heard);
    note_tool second "write_file";
    check (list (pair string string)) "every report names the workspace and Keeper"
      [ base_path, "alpha"; base_path, "alpha"; base_path, "alpha"; base_path, "alpha" ]
      !heard)
;;

let test_a_burst_is_sent_once_after_the_interval () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  let base_path = Unix.realpath (Filename.temp_dir "turn-preview-announce-" "") in
  Fun.protect
    ~finally:(fun () ->
      Keeper_turn_preview_signal.install ignore_writes;
      Fs_compat.remove_tree base_path)
    (fun () ->
      ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
      let heard = Eio.Stream.create max_int in
      let id = "turn-preview-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match
            Json_util.assoc_string_opt "type" event.ext_payload,
            Json_util.assoc_string_opt "name" event.ext_payload
          with
          | Some kind, Some name
            when String.equal kind Keeper_turn_preview_signal.changed_event ->
            Eio.Stream.add heard name
          | (Some _ | None), (Some _ | None) -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        Eio.Switch.run @@ fun sw ->
        Server_turn_preview_broadcast.install ~sw ~clock;
        let expect_one label =
          match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok name -> check string label "alpha" name
          | Error `Timeout -> failf "%s: no preview signal" label
        in
        let expect_quiet label =
          match Eio.Time.with_timeout clock quiet_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok name -> failf "%s: a second signal for %s" label name
          | Error `Timeout -> ()
        in
        let writer = reset ~base_path "alpha" in
        expect_one "a new preview is sent at once";
        note_tool writer "read_file";
        note_tool writer "write_file";
        note_tool writer "list_files";
        expect_one "the burst is sent when the interval ends";
        expect_quiet "the burst is sent once"))
;;

let () =
  run "turn_preview_announce"
    [ ( "preview"
      , [ test_case "only the shown writer reports" `Quick test_only_the_shown_writer_reports
        ; test_case "a burst is sent once after the interval" `Quick
            test_a_burst_is_sent_once_after_the_interval
        ] )
    ]
;;
