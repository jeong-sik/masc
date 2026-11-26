(* A write to the preview a Keeper's turns answer shows tells
   that workspace's turns readers, at most once per interval for a burst. *)

open Alcotest
open Masc

(* Long enough for the fiber to wake on an idle machine. *)
let signal_wait_s = 5.0

(* Several intervals: a second send for one burst would land inside it. *)
let quiet_wait_s = Server_turn_preview_broadcast.post_interval_s *. 4.0

let ignore_writes ~base_path:_ ~keeper_name:_ = ()

(* The turns answer reads a preview only for the Owner slot that owns it. *)
let reset_owned ~base_path keeper_name =
  Keeper_turn_preview_owner.with_owner ~interrupt_token:(Keeper_interrupt_token.fresh ())
    ~observation:(Keeper_turn_preview_owner.create_turn_observation ()) (fun () ->
      Keeper_turn_preview.reset ~base_path ~keeper_name ~execution_scope:None ~turn_ref:None
        ~now:(Unix.gettimeofday ()) ~redaction:Keeper_secret_redaction.empty)
;;

let reset_unowned ~base_path keeper_name =
  Keeper_turn_preview.reset ~base_path ~keeper_name ~execution_scope:None ~turn_ref:None
    ~now:(Unix.gettimeofday ()) ~redaction:Keeper_secret_redaction.empty
;;

(* The before-tool hook: a call starts here and stays open until it returns. *)
let note_tool writer tool =
  Keeper_turn_preview.note_tool_started ~writer:(Some writer) ~now:(Unix.gettimeofday ())
    ~tool_use_id:None ~tool_name:tool ~cohort:None ~reach:None

let test_only_the_shown_writer_reports () =
  (* An Owner slot is a fiber binding, so the writers run in Eio. *)
  Eio_main.run @@ fun _env ->
  let heard = ref [] in
  Keeper_turn_preview_signal.install (fun ~base_path ~keeper_name ->
    heard := (base_path, keeper_name) :: !heard);
  Fun.protect ~finally:(fun () -> Keeper_turn_preview_signal.install ignore_writes) (fun () ->
    let base_path = "turn-preview-announce" in
    let unowned = reset_unowned ~base_path "alpha" in
    note_tool unowned "read_file";
    check int "a preview outside an Owner slot reports nothing" 0 (List.length !heard);
    let first = reset_owned ~base_path "alpha" in
    check int "installing a preview reports it" 1 (List.length !heard);
    note_tool first "read_file";
    check int "a note on the shown preview reports it" 2 (List.length !heard);
    let second = reset_owned ~base_path "alpha" in
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
  let config = Workspace.default_config base_path in
  let keeper_name = "alpha" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_turn_preview_signal.install ignore_writes;
      Fs_compat.remove_tree base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None);
      let meta =
        match Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String keeper_name; "trace_id", `String "trace-preview";
                    "activation_mode", `String "manual" ])
        with
        | Ok meta -> meta
        | Error detail -> fail detail
      in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      let secret = "preview-announcement-fixture-secret" in
      let secret_file = Filename.concat base_path "test-secret" in
      Out_channel.with_open_bin secret_file (fun out -> output_string out (secret ^ "\n"));
      let redaction =
        Keeper_secret_redaction.snapshot_with_additional_secret_files
          ~redact_identity_scalars:true ~additional_secret_files:[ secret_file ]
          ~base_path ~keeper_name
      in
      let heard = Eio.Stream.create max_int in
      let id = "turn-preview-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match Json_util.assoc_string_opt "type" event.ext_payload with
          | Some kind
            when String.equal kind Keeper_turn_preview_signal.changed_event ->
            Eio.Stream.add heard event.ext_payload
          | Some _ | None -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        Eio.Switch.run @@ fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
        (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
           ~on_turn_slot_released:None config with
         | Ok _ -> ()
         | Error err -> fail (Keeper_owner_registry.install_error_to_string err));
        let owner =
          match Keeper_owner_registry.get ~base_path ~keeper_name with
          | Ok owner -> owner
          | Error err -> fail (Keeper_owner_registry.lookup_error_to_string err)
        in
        Server_turn_preview_broadcast.install ~sw ~clock;
        let expect_one label =
          match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok event -> event
          | Error `Timeout -> failf "%s: no preview signal" label
        in
        let expect_quiet label =
          match Eio.Time.with_timeout clock quiet_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok event -> failf "%s: a second signal: %s" label (Yojson.Safe.to_string event)
          | Error `Timeout -> ()
        in
        let observe_turn () =
          let open Yojson.Safe.Util in
          let token =
            match Keeper_owner.turn_in_flight owner with
            | Some slot -> Keeper_interrupt_token.to_string slot.interrupt_token
            | None -> fail "maintenance must hold the registered Owner slot"
          in
          let writer =
            Keeper_turn_preview.reset ~base_path ~keeper_name ~execution_scope:None
              ~turn_ref:None ~now:(Unix.gettimeofday ()) ~redaction
          in
          let first = expect_one "a new preview is sent at once" in
          check string "the announcement names the Keeper" keeper_name
            (first |> member "name" |> to_string);
          check string "its key matches the current Owner slot"
            Digest.BLAKE256.(to_hex (string token))
            (first |> member "observation" |> member "owner_key" |> to_string);
          let text = "before " ^ secret ^ " after" in
          Keeper_turn_preview.note_text ~writer:(Some writer) ~now:(Unix.gettimeofday ()) text;
          note_tool writer "read_file";
          note_tool writer "write_file";
          note_tool writer "list_files";
          let latest = expect_one "the burst is sent when the interval ends" in
          let preview event = event |> member "observation" |> member "preview" in
          let revision event = preview event |> member "revision" |> to_int in
          check bool "the snapshot revision advances" true (revision latest > revision first);
          check string "the burst carries its latest tool" "list_files"
            (preview latest |> member "last_tool" |> to_string);
          check string "the burst carries redacted preview text"
            (Keeper_secret_redaction.redact_text redaction text)
            (preview latest |> member "text_tail" |> to_string);
          let wire = Yojson.Safe.to_string latest in
          List.iter (fun value ->
            check bool "the wire hides the exact credential" false
              (String_util.contains_substring wire value))
            [ token; Keeper_owner.chat_control_token owner; secret ];
          expect_quiet "the burst is sent once";
          let reason = "provider refused input" in
          Keeper_turn_preview.note_failure ~writer:(Some writer) ~now:(Unix.gettimeofday ())
            ~runtime_id:"preview-fixture" (reason ^ " containing " ^ secret);
          let failure = expect_one "the provider failure is sent" in
          let failed_preview = preview failure in
          check string "the observer sees the failure activity" "failed"
            (failed_preview |> member "activity" |> to_string);
          let status = failed_preview |> member "status_text" |> to_string in
          check bool "the observer can read the failure reason" true
            (String_util.contains_substring status reason);
          check bool "the failure excludes the exact Keeper secret" false
            (String_util.contains_substring (Yojson.Safe.to_string failure) secret)
        in
        match Keeper_owner.run_maintenance_if_idle owner observe_turn with
        | Ok (`Ran ()) -> ()
        | Ok (`Busy _) -> fail "the registered Owner should be idle"
        | Error err -> fail (Keeper_owner.error_to_string err)))
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
