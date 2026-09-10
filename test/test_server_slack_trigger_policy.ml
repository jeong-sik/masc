(* RFC-0317 / masc#29078 — the Slack gateway's trigger-policy resolution must
   delegate to the single canonical grammar in [Slack_gateway_state] and apply
   the same precedence and failure posture as the Discord sibling
   ([test_server_discord_trigger_policy]).

   These assertions pin the contract on both configured planes: env wins over
   TOML, a blank/unset env falls through to TOML, a missing file/key yields the
   default, and an unparseable value on *either* plane is a typed load error.
   Neither plane may quietly resolve to a policy the operator did not write —
   the default is [Mention_or_thread], which is wider than [Mention_only], so a
   silent fallback would broaden the trigger surface on a typo. *)

open Alcotest
open Masc
module G = Server_slack_in_process_gateway
module State = Channel_gate_slack_state

external unsetenv : string -> unit = "masc_test_unsetenv"

let ps p = Slack_gateway_state.trigger_policy_to_string p
let default_str = ps G.default_trigger_policy

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-slack-trigger-policy-status-%d-%d"
         (Unix.getpid ())
         (Random.bits ()))
  in
  with_env Env_config_core.base_path_env_key base_path (fun () ->
    with_env Env_config_core.base_path_input_env_key base_path f)
;;

let with_temp_toml content f =
  let path = Filename.temp_file "masc-slack-trigger-policy-" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       let out = open_out_bin path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr out)
         (fun () -> output_string out content);
       f path)
;;

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-slack-trigger-policy-root-%d-%d"
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

(* Point the config resolver at a temp config root so the TOML plane is under
   test control. MASC_CONFIG_DIR is the documented override the sandbox suites
   already use. *)
let with_config_root dir f =
  with_env "MASC_CONFIG_DIR" dir @@ fun () ->
  with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "1" @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset f
;;

let load_error_to_string error = G.trigger_policy_load_error_to_string error

let test_with_env_restores_unset () =
  let key = "MASC_TEST_WITH_ENV_RESTORE_PROBE" in
  unsetenv key;
  with_env key "all" (fun () ->
    check (option string) "set inside scope" (Some "all") (Sys.getenv_opt key));
  check (option string) "restored unset" None (Sys.getenv_opt key)
;;

(* -- resolved_trigger_policy: runtime.toml > default -- *)

let write_policy dir raw =
  write_file (Filename.concat dir "runtime.toml")
    (Printf.sprintf "[slack]\ntrigger_policy = %S\n" raw)
;;

let test_valid_values_parse_through () =
  (* Each valid form resolves to exactly what the strict grammar yields, so the
     config boundary delegates rather than re-implementing the grammar. *)
  List.iter
    (fun raw ->
      let expected =
        match Slack_gateway_state.parse_trigger_policy raw with
        | Ok p -> ps p
        | Error msg -> failf "strict grammar rejected %S: %s" raw msg
      in
      with_temp_dir @@ fun dir ->
      write_policy dir raw;
      with_config_root dir @@ fun () ->
      match G.resolved_trigger_policy () with
      | Ok p ->
        check string (Printf.sprintf "%S resolves through" raw) expected (ps p)
      | Error e ->
        failf "expected %S to resolve, got error: %s" raw
          (load_error_to_string e))
    [ "mention_only"; "mention_or_thread"; "all"; "user_only:U123" ]
;;

let test_invalid_value_is_load_error () =
  (* A typo must not resolve. Before masc#29078 this logged a WARN and returned
     Mention_or_thread, quietly widening the trigger surface. *)
  with_temp_dir @@ fun dir ->
  write_policy dir "mention_ony";
  with_config_root dir @@ fun () ->
  match G.resolved_trigger_policy () with
  | Error (G.Trigger_policy_invalid _) -> ()
  | Error e -> failf "expected policy_invalid, got: %s" (load_error_to_string e)
  | Ok p -> failf "invalid value must not resolve, got %s" (ps p)
;;

let test_user_only_empty_id_is_load_error () =
  (* The strict grammar rejects an empty id; the boundary must surface that
     rather than constructing User_only "" or falling back. *)
  with_temp_dir @@ fun dir ->
  write_policy dir "user_only:";
  with_config_root dir @@ fun () ->
  match G.resolved_trigger_policy () with
  | Error (G.Trigger_policy_invalid _) -> ()
  | Error e -> failf "expected policy_invalid, got: %s" (load_error_to_string e)
  | Ok p -> failf "empty user_only id must not resolve, got %s" (ps p)
;;

let test_blank_value_is_unset () =
  with_temp_dir @@ fun dir ->
  write_policy dir "   ";
  with_config_root dir @@ fun () ->
  match G.resolved_trigger_policy () with
  | Ok p -> check string "blank value is unset" default_str (ps p)
  | Error e -> failf "expected default, got error: %s" (load_error_to_string e)
;;

let test_all_unset_is_default () =
  with_temp_dir @@ fun dir ->
  with_config_root dir @@ fun () ->
  match G.resolved_trigger_policy () with
  | Ok p -> check string "default when nothing configured" default_str (ps p)
  | Error e -> failf "expected default, got error: %s" (load_error_to_string e)
;;

(* -- load_trigger_policy_from_toml: the TOML plane in isolation -- *)

let test_missing_runtime_toml_is_typed_missing () =
  let path = Filename.temp_file "masc-slack-trigger-policy-missing-" ".toml" in
  Sys.remove path;
  match G.load_trigger_policy_from_toml ~path with
  | Ok G.Runtime_toml_missing -> ()
  | Ok G.Trigger_policy_missing ->
    fail "expected missing runtime.toml, got missing key"
  | Ok (G.Trigger_policy_loaded policy) ->
    failf "expected missing runtime.toml, got policy %s" (ps policy)
  | Error error ->
    failf "expected typed missing, got %s" (load_error_to_string error)
;;

let test_dangling_runtime_toml_symlink_is_unreadable () =
  let link_path = Filename.temp_file "masc-slack-trigger-policy-link-" ".toml" in
  Sys.remove link_path;
  let missing_target = link_path ^ ".missing" in
  Unix.symlink missing_target link_path;
  Fun.protect
    ~finally:(fun () -> try Sys.remove link_path with Sys_error _ -> ())
    (fun () ->
       match G.load_trigger_policy_from_toml ~path:link_path with
       | Error (G.Runtime_toml_unreadable _) -> ()
       | Error error ->
         failf "expected unreadable dangling symlink, got %s" (load_error_to_string error)
       | Ok _ -> fail "dangling runtime.toml symlink must not enable fallback")
;;

let test_missing_key_is_deliberate_no_config () =
  with_temp_toml "[server]\nport = 8935\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Ok G.Trigger_policy_missing -> ()
    | Ok G.Runtime_toml_missing -> fail "runtime.toml should exist"
    | Ok (G.Trigger_policy_loaded policy) ->
      failf "expected missing Slack key, got policy %s" (ps policy)
    | Error error ->
      failf "expected missing Slack key, got %s" (load_error_to_string error))
;;

let test_malformed_runtime_toml_is_error () =
  with_temp_toml "[slack\ntrigger_policy = \"all\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Runtime_toml_invalid _) -> ()
    | Error error ->
      failf "expected invalid TOML, got %s" (load_error_to_string error)
    | Ok _ -> fail "malformed runtime.toml must fail closed")
;;

let test_valid_runtime_toml_loads_policy () =
  with_temp_toml "[slack]\ntrigger_policy = \"all\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Ok (G.Trigger_policy_loaded policy) ->
      check string "policy" "all" (ps policy)
    | Ok G.Runtime_toml_missing -> fail "runtime.toml should exist"
    | Ok G.Trigger_policy_missing -> fail "trigger policy should be present"
    | Error error ->
      failf "expected valid policy, got %s" (load_error_to_string error))
;;

let test_wrong_type_runtime_toml_is_error () =
  with_temp_toml "[slack]\ntrigger_policy = 42\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid policy type, got %s" (load_error_to_string error)
    | Ok _ -> fail "wrong trigger-policy type must fail closed")
;;

let test_wrong_type_slack_parent_is_error () =
  with_temp_toml "slack = \"not-a-table\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid Slack table, got %s" (load_error_to_string error)
    | Ok _ -> fail "wrong Slack parent type must fail closed")
;;

let test_invalid_runtime_toml_policy_is_error () =
  with_temp_toml "[slack]\ntrigger_policy = \"mention_ony\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid policy value, got %s" (load_error_to_string error)
    | Ok _ -> fail "invalid trigger-policy value must fail closed")
;;

let test_startup_error_is_operator_visible () =
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    with_temp_base (fun () ->
      State.record_startup_error "invalid Slack trigger policy";
      Fun.protect
        ~finally:State.clear_startup_error
        (fun () ->
           let status = State.status_json () in
           check bool "not available despite app token" false
             Yojson.Safe.Util.(status |> member "available" |> to_bool);
           check bool "not connected" false
             Yojson.Safe.Util.(status |> member "connected" |> to_bool);
           check string "status uses connector vocabulary" "offline"
             Yojson.Safe.Util.(status |> member "status" |> to_string);
           check string "error" "invalid Slack trigger policy"
             Yojson.Safe.Util.(status |> member "error" |> to_string))))
;;

let slack_message ?(user_name = Some "operator") ~ts () =
  Slack_gateway_state.Message_create
    { channel_id = "C123"
    ; thread_ts = None
    ; user_id = "U123"
    ; user_name
    ; text = "wake the keeper"
    ; ts
    ; mentions_bot = true
    ; bot_id = None
    ; files = []
    }
;;

(* Slack omits [user_name] when the workspace directory is unavailable. The
   gateway used to put [user_id] in its place and wrap it back into [Some], so
   the durable row said the author is called [U123] and the chat pane drew an
   id where a name goes.

   Driven through [submit_event] rather than the recorder underneath it: the
   collapse was in the handler, and a test that called past it stayed green
   with the collapse restored. *)
(* The directory holds names in memory for an hour and loses them on restart,
   so the same person arrives named and then not -- one channel had twelve of
   each from one human. A name seen once is written down and spoken for the
   messages that arrive without one.

   Two submissions through the real path: the first carries a name, the second
   carries none. *)
let test_a_name_seen_once_is_remembered () =
  with_temp_base (fun () ->
    match State.bind ~channel_id:"C123" ~keeper_name:"luna" ~actor_name:"test" with
    | Error detail -> fail detail
    | Ok _ ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let ingress =
        Connector_ingress_lane.create ~sw ~on_failure:(fun _ -> ()) ()
      in
      let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
          ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_
          ~metadata:_ ~content:_ =
        Gate_protocol.Reply
          { content = "queued"; structured = None; stats = None
          ; message_request = None }
      in
      let submit ~user_name ~ts =
        G.For_testing.submit_event ~team_id:"T123" ~deliver:(fun () -> ())
          ingress ~dispatch_for_delivery:(fun _ -> dispatch)
          ~clock:(Eio.Stdenv.clock env)
          ~base_dir:(Env_config_core.base_path ())
          (slack_message ~user_name ~ts ())
      in
      submit ~user_name:(Some "Vincent") ~ts:"1710000000.000001";
      submit ~user_name:None ~ts:"1710000000.000002";
      let names =
        Keeper_external_attention.load_events
          ~base_path:(Env_config_core.base_path ())
          ~keeper_name:"luna"
        |> List.filter_map (function
             | Keeper_external_attention.Recorded item -> Some item)
        |> List.map (fun item ->
             item.Keeper_external_attention.actor
               .Keeper_external_attention.display_name)
      in
      check int "both messages were recorded" 2 (List.length names);
      check (list (option string))
        "the message with no name speaks the one seen before"
        [ Some "Vincent"; Some "Vincent" ]
        names)
;;

let test_a_missing_author_name_is_not_replaced_by_the_id () =
  with_temp_base (fun () ->
    match State.bind ~channel_id:"C123" ~keeper_name:"luna" ~actor_name:"test" with
    | Error detail -> fail detail
    | Ok _ ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let ingress =
        Connector_ingress_lane.create ~sw ~on_failure:(fun _ -> ()) ()
      in
      let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
          ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_
          ~metadata:_ ~content:_ =
        Gate_protocol.Reply
          { content = "queued"
          ; structured = None
          ; stats = None
          ; message_request = None
          }
      in
      G.For_testing.submit_event
        ~team_id:"T123"
        ~deliver:(fun () -> ())
        ingress
        ~dispatch_for_delivery:(fun _ -> dispatch)
        ~clock:(Eio.Stdenv.clock env)
        ~base_dir:(Env_config_core.base_path ())
        (slack_message ~user_name:None ~ts:"1710000000.999999" ());
      match
        Keeper_external_attention.load_events
          ~base_path:(Env_config_core.base_path ())
          ~keeper_name:"luna"
        |> List.filter_map (function
             | Keeper_external_attention.Recorded item -> Some item)
      with
      | [] -> fail "no attention recorded for a bound channel"
      | item :: _ ->
        check (option string) "the id is not offered as a name" None
          item.Keeper_external_attention.actor
            .Keeper_external_attention.display_name;
        (* The id itself is still carried: an author nobody named is still a
           particular author. *)
        check (option string) "and the author is still identified" (Some "U123")
          item.Keeper_external_attention.actor
            .Keeper_external_attention.actor_id)
;;

let test_bound_message_queues_exact_slack_ts () =
  try
    with_temp_base (fun () ->
    match
      State.bind ~channel_id:"C123" ~keeper_name:"luna" ~actor_name:"test"
    with
    | Error detail -> fail detail
    | Ok _ ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let observed, resolve_observed = Eio.Promise.create () in
      let ingress =
        Connector_ingress_lane.create ~sw
          ~on_failure:(fun failure ->
            Eio.Promise.resolve resolve_observed failure)
          ()
      in
      let accepted_before_delivery = ref false in
      let observed_delivery = ref None in
      let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
          ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_
          ~content:_ =
        accepted_before_delivery := true;
        Gate_protocol.Reply
          { content = "queued"
          ; structured = None
          ; stats = None
          ; message_request = None
          }
      in
      let dispatch_for_delivery delivery =
        observed_delivery := Some delivery;
        dispatch
      in
      G.For_testing.submit_event
        ~team_id:"T123"
        ~deliver:(fun () ->
          if not !accepted_before_delivery then
            failwith "delivery ran before durable accept";
          failwith "observe Slack ingress identity")
        ingress ~dispatch_for_delivery
        ~clock:(Eio.Stdenv.clock env)
        ~base_dir:(Env_config_core.base_path ())
        (slack_message ~ts:"1710000000.123456" ());
      check bool "accept completed before handoff" true !accepted_before_delivery;
      (match !observed_delivery with
       | Some
           { continuation_channel =
               Keeper_continuation_channel.Slack
                 { channel_id; user_id; team_id; thread_ts }
           ; surface =
               Surface_ref.Slack
                 { team_id = surface_team_id
                 ; channel_id = surface_channel_id
                 ; thread_ts = surface_thread_ts
                 }
           ; conversation_id
           ; external_message_id
           ; workspace_id
           } ->
         check string "Slack delivery channel" "C123" channel_id;
         check string "Slack delivery actor" "U123" user_id;
         check (option string) "Slack delivery team" (Some "T123") team_id;
         check (option string) "Slack delivery workspace identity"
           (Some "T123") workspace_id;
         check (option string) "Slack reply thread"
           (Some "1710000000.123456") thread_ts;
         check string "Slack surface channel" "C123" surface_channel_id;
         check (option string) "Slack surface team" (Some "T123") surface_team_id;
         check (option string) "Slack surface preserves reply thread"
           (Some "1710000000.123456") surface_thread_ts;
         check (option string) "Slack conversation identity"
           (Some "slack:channel:C123") conversation_id;
         check (option string) "Slack external event identity"
           (Some "1710000000.123456") external_message_id
       | Some _ -> fail "Slack leaf emitted another connector projection"
       | None -> fail "Slack leaf did not emit a delivery projection");
      let failure = Eio.Promise.await observed in
      check string "exact Slack event ts" "1710000000.123456"
        failure.Connector_ingress_lane.event_id.opaque_id;
      check string "typed source" "slack_triggered"
        failure.event_id.source;
      (match failure.lane with
       | Connector_ingress_lane.Keeper_lane keeper_name ->
         check string "resolved Keeper lane" "luna" keeper_name
       | Connector_ingress_lane.Connector_lane connector_id ->
         failf "expected Keeper lane, got connector:%s" connector_id);
      Eio.Switch.fail sw Exit)
  with Exit -> ()
;;

let test_binding_store_failure_does_not_enqueue () =
  try
    with_temp_base (fun () ->
    let binding_path =
      Filename.concat
        (Env_config_core.base_path ())
        ".gate/runtime/slack/bindings.json"
    in
    Fs_compat.mkdir_p (Filename.dirname binding_path);
    let out = open_out_bin binding_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr out)
      (fun () -> output_string out "{not-json");
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let dispatch_called = ref false in
    let ingress =
      Connector_ingress_lane.create ~sw
        ~on_failure:(fun _ -> fail "binding failure must not enqueue")
        ()
    in
    let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
        ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_
        ~content:_ =
      dispatch_called := true;
      Gate_protocol.Unavailable_result
    in
    let dispatch_for_delivery _delivery = dispatch in
    G.For_testing.submit_event
      ~deliver:(fun () -> fail "binding failure must not schedule delivery")
      ingress ~dispatch_for_delivery
      ~clock:(Eio.Stdenv.clock env)
      ~base_dir:(Env_config_core.base_path ())
      (slack_message ~ts:"1710000000.654321" ());
    Eio.Fiber.yield ();
    check bool "no volatile job accepted" false !dispatch_called;
    Eio.Switch.fail sw Exit)
  with Exit -> ()
;;

module Gw = Slack_gateway_state

(* -- the params plane above env and TOML -------------------------- *)

(* The gateway publishes what it resolved from env and runtime.toml, and the
   param answers with that until an operator overrides it from the params
   surface. This is the layer that lets a policy change take effect without a
   restart, so what it must hold is: an override wins, and clearing one returns
   to the configured answer rather than to the hardcoded baseline. *)

let installed_policy () = ps (Runtime_params.get Runtime_settings.slack_trigger_policy)

let set_override policy =
  match Runtime_params.set Runtime_settings.slack_trigger_policy policy with
  | Ok () -> ()
  | Error detail -> fail ("override rejected: " ^ detail)
;;

let with_clean_override f =
  Fun.protect
    ~finally:(fun () -> Runtime_params.clear Runtime_settings.slack_trigger_policy)
    f
;;

let test_configured_answers_without_override () =
  with_clean_override (fun () ->
    Runtime_params.clear Runtime_settings.slack_trigger_policy;
    Runtime_settings.set_slack_trigger_policy_configured Gw.All;
    check string "the configured policy answers when nothing overrides it"
      (ps Gw.All) (installed_policy ()))
;;

let test_override_wins_over_configured () =
  with_clean_override (fun () ->
    Runtime_settings.set_slack_trigger_policy_configured Gw.All;
    set_override Gw.Mention_only;
    check string "an operator override outranks env and TOML"
      (ps Gw.Mention_only) (installed_policy ()))
;;

let test_clear_returns_to_configured () =
  with_clean_override (fun () ->
    Runtime_settings.set_slack_trigger_policy_configured Gw.Mention_or_thread;
    set_override Gw.All;
    Runtime_params.clear Runtime_settings.slack_trigger_policy;
    check string "clearing returns to what env and TOML said, not the baseline"
      (ps Gw.Mention_or_thread) (installed_policy ()))
;;

(* The parameterized form is not offered by the picker but must still round
   trip, or an operator who types it loses it on the next read. *)
let test_user_only_round_trips_through_the_param () =
  with_clean_override (fun () ->
    set_override (Gw.User_only "123456789");
    check string "user_only survives serialize and deserialize"
      (ps (Gw.User_only "123456789")) (installed_policy ()))
;;

(* The connector surface reads a mirror written at gateway startup. A param
   set has to carry it along, or the screen an operator just used goes on
   reporting the policy from boot. *)
let test_setting_the_param_moves_the_display_mirror () =
  with_clean_override (fun () ->
    Channel_gate_slack_state.set_trigger_policy Gw.Mention_or_thread;
    let key = Runtime_params.key Runtime_settings.slack_trigger_policy in
    (match
       Server_routes_http_routes_activity.mutate_runtime_param_with_effects
         ~base_path:"" ~param_key:key
         (fun () -> Runtime_params.set_by_key_with_change key (`String "mention_only"))
     with
     | Ok ((_ : Runtime_params.json_change), (_ : (string * Yojson.Safe.t) list)) -> ()
     | Error detail -> fail ("param mutation rejected: " ^ detail));
    check (option string) "the surface reports what was just set"
      (Some (ps Gw.Mention_only))
      (Option.map ps (Channel_gate_slack_state.get_trigger_policy ())))
;;

let () =
  run "server_slack_trigger_policy"
    [ ( "resolved_trigger_policy (env > TOML > default)"
      , [ test_case "with_env restores unset" `Quick test_with_env_restores_unset
        ; test_case "valid values resolve through strict grammar" `Quick
            test_valid_values_parse_through
        ; test_case "invalid value => load error (no silent default)" `Quick
            test_invalid_value_is_load_error
        ; test_case "user_only empty id => load error" `Quick
            test_user_only_empty_id_is_load_error
        ; test_case "blank value => unset" `Quick test_blank_value_is_unset
        ; test_case "all unset => default" `Quick test_all_unset_is_default
        ] )
    ; ( "runtime.toml loading"
      , [ test_case "missing file => typed missing" `Quick
            test_missing_runtime_toml_is_typed_missing
        ; test_case "dangling symlink => unreadable" `Quick
            test_dangling_runtime_toml_symlink_is_unreadable
        ; test_case "missing key => deliberate no-config" `Quick
            test_missing_key_is_deliberate_no_config
        ; test_case "malformed file => error" `Quick
            test_malformed_runtime_toml_is_error
        ; test_case "valid file => configured policy" `Quick
            test_valid_runtime_toml_loads_policy
        ; test_case "wrong field type => error" `Quick
            test_wrong_type_runtime_toml_is_error
        ; test_case "wrong Slack table type => error" `Quick
            test_wrong_type_slack_parent_is_error
        ; test_case "invalid policy value => error" `Quick
            test_invalid_runtime_toml_policy_is_error
        ; test_case "startup error => offline with error" `Quick
            test_startup_error_is_operator_visible
        ] )
    ; ( "ingress handoff"
      , [ test_case "bound message retains exact Slack ts" `Quick
            test_bound_message_queues_exact_slack_ts
        ; test_case "a missing author name is not replaced by the id" `Quick
            test_a_missing_author_name_is_not_replaced_by_the_id
        ; test_case "a name seen once is remembered" `Quick
            test_a_name_seen_once_is_remembered
        ; test_case "binding store failure does not enqueue" `Quick
            test_binding_store_failure_does_not_enqueue
        ] )
    ; ( "params_plane"
      , [ test_case "configured answers without an override" `Quick
            test_configured_answers_without_override
        ; test_case "override wins over configured" `Quick
            test_override_wins_over_configured
        ; test_case "clear returns to configured" `Quick
            test_clear_returns_to_configured
        ; test_case "user_only round trips" `Quick
            test_user_only_round_trips_through_the_param
        ; test_case "a param set moves the display mirror" `Quick
            test_setting_the_param_moves_the_display_mirror
        ] )
    ]
