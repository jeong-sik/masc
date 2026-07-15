(* RFC-0223 P4 — Keeper_surface_post target resolution + assistant-only
   store append.

   resolve_target is pure (surface label + channel arg + bindings in,
   target or error out). The Discord transport path needs a live REST
   client and stays operational; the dashboard persistence path is
   covered against a temp store here. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SP = Masc.Keeper_surface_post

let target_pp fmt = function
  | SP.To_dashboard -> Format.fprintf fmt "To_dashboard"
  | SP.To_discord { channel_id } ->
      Format.fprintf fmt "To_discord{%s}" channel_id
  | SP.To_slack { channel_id; blocks } ->
      let blocks_label =
        match blocks with None -> "no-blocks" | Some [] -> "empty" | Some _ -> "blocks"
      in
      Format.fprintf fmt "To_slack{%s,%s}" channel_id blocks_label

let target : SP.post_target testable = testable target_pp ( = )

let resolve = SP.resolve_target

(* ── resolve_target ─────────────────────────────────────────────── *)

let test_dashboard_always_resolves () =
  check (result target string) "no bindings needed" (Ok SP.To_dashboard)
    (resolve ~surface:"dashboard" ~channel_id:None ~bound_discord_channels:[] ())

let test_discord_unbound_is_error () =
  match resolve ~surface:"discord" ~channel_id:None ~bound_discord_channels:[] () with
  | Error message ->
      check bool "names the unbound condition" true
        (Astring.String.is_infix ~affix:"no Discord channel binding" message)
  | Ok _ -> fail "unbound discord must not resolve"

let test_discord_single_binding_resolves_implicitly () =
  check (result target string) "single binding"
    (Ok (SP.To_discord { channel_id = "98791450001" }))
    (resolve ~surface:"discord" ~channel_id:None
       ~bound_discord_channels:[ "98791450001" ] ())

let test_discord_multiple_bindings_require_channel_id () =
  (match
     resolve ~surface:"discord" ~channel_id:None
       ~bound_discord_channels:[ "111"; "222" ] ()
   with
  | Error message ->
      check bool "lists bound channels" true
        (Astring.String.is_infix ~affix:"111, 222" message)
  | Ok _ -> fail "ambiguous binding must not resolve");
  check (result target string) "explicit channel_id picks one"
    (Ok (SP.To_discord { channel_id = "222" }))
    (resolve ~surface:"discord" ~channel_id:(Some "222")
       ~bound_discord_channels:[ "111"; "222" ] ())

let test_discord_foreign_channel_id_is_error () =
  match
    resolve ~surface:"discord" ~channel_id:(Some "999")
      ~bound_discord_channels:[ "111" ] ()
  with
  | Error message ->
      check bool "names the rejected id" true
        (Astring.String.is_infix ~affix:"999" message)
  | Ok _ -> fail "foreign channel_id must not resolve"

let test_slack_unbound_is_error () =
  match
    resolve ~surface:"slack" ~channel_id:None
      ~bound_discord_channels:[] ~bound_slack_channels:[] ()
  with
  | Error message ->
      check bool "names the unbound condition" true
        (Astring.String.is_infix ~affix:"no Slack channel binding" message)
  | Ok _ -> fail "unbound slack must not resolve"

let test_slack_single_binding_resolves_implicitly () =
  check (result target string) "single slack binding"
    (Ok (SP.To_slack { channel_id = "C123456"; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:None
       ~bound_discord_channels:[] ~bound_slack_channels:[ "C123456" ] ())

let test_slack_multiple_bindings_require_channel_id () =
  (match
     resolve ~surface:"slack" ~channel_id:None
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ()
   with
  | Error message ->
      check bool "lists bound slack channels" true
        (Astring.String.is_infix ~affix:"AAA, BBB" message)
  | Ok _ -> fail "ambiguous slack binding must not resolve");
  check (result target string) "explicit channel_id picks one"
    (Ok (SP.To_slack { channel_id = "BBB"; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:(Some "BBB")
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ())

let test_slack_foreign_channel_id_is_error () =
  match
    resolve ~surface:"slack" ~channel_id:(Some "ZZZ")
      ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA" ] ()
  with
  | Error message ->
      check bool "names the rejected slack id" true
        (Astring.String.is_infix ~affix:"ZZZ" message)
  | Ok _ -> fail "foreign slack channel_id must not resolve"

let test_unsupported_surface_is_error () =
  List.iter
    (fun surface ->
      match resolve ~surface ~channel_id:None ~bound_discord_channels:[] () with
      | Error message ->
          check bool (surface ^ " unsupported") true
            (Astring.String.is_infix ~affix:"not supported" message)
      | Ok _ -> fail (surface ^ " must not resolve in P4"))
    [ "telegram"; "openclaw" ]

(* ── set_blocks ─────────────────────────────────────────────────── *)

let test_set_blocks_attaches_to_slack () =
  let block = `Assoc [ ("type", `String "section") ] in
  let resolved =
    SP.set_blocks (SP.To_slack { channel_id = "C1"; blocks = None }) (Some [ block ])
  in
  check (result target string) "blocks attached"
    (Ok (SP.To_slack { channel_id = "C1"; blocks = Some [ block ] }))
    (Ok resolved)

let test_set_blocks_ignores_other_targets () =
  let block = `Assoc [ ("type", `String "section") ] in
  check target "dashboard unchanged" SP.To_dashboard
    (SP.set_blocks SP.To_dashboard (Some [ block ]));
  check target "discord unchanged"
    (SP.To_discord { channel_id = "D1" })
    (SP.set_blocks (SP.To_discord { channel_id = "D1" }) (Some [ block ]))

(* ── append_assistant_message ───────────────────────────────────── *)

let with_temp_base_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "surface-post-%d" (Unix.getpid ()))
  in
  let masc = Filename.concat dir ".masc" in
  let keeper_chat = Filename.concat masc "keeper_chat" in
  List.iter
    (fun d -> if not (Sys.file_exists d) then Unix.mkdir d 0o755)
    [ dir; masc; keeper_chat ];
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun f -> try Sys.remove (Filename.concat keeper_chat f) with _ -> ())
        (try Sys.readdir keeper_chat with Sys_error _ -> [||]))
    (fun () -> f dir)

let test_assistant_message_persists_with_source () =
  with_temp_base_dir (fun base_dir ->
      Store.append_assistant_message ~base_dir ~keeper_name:"post-keeper"
        ~content:"keeper-initiated hello"
        ~surface:
          (Surface_ref.Discord
             {
               guild_id = None;
               channel_id = "chan-1";
               parent_channel_id = None;
               thread_id = None;
             })
        ();
      let messages = Store.load ~base_dir ~keeper_name:"post-keeper" in
      check int "one line" 1 (List.length messages);
      let m = List.hd messages in
      check string "role" "assistant" (Store.Role.to_label m.Store.role);
      check string "content" "keeper-initiated hello" m.Store.content;
      check (option string) "source" (Some "discord") m.Store.source;
      check bool "no speaker on keeper output" true (m.Store.speaker = None))

let () =
  run "keeper_surface_post"
    [
      ( "resolve_target",
        [
          test_case "dashboard always resolves" `Quick
            test_dashboard_always_resolves;
          test_case "discord unbound is an error" `Quick
            test_discord_unbound_is_error;
          test_case "single binding resolves implicitly" `Quick
            test_discord_single_binding_resolves_implicitly;
          test_case "multiple bindings require channel_id" `Quick
            test_discord_multiple_bindings_require_channel_id;
          test_case "foreign channel_id is an error" `Quick
            test_discord_foreign_channel_id_is_error;
          test_case "slack unbound is an error" `Quick
            test_slack_unbound_is_error;
          test_case "slack single binding resolves implicitly" `Quick
            test_slack_single_binding_resolves_implicitly;
          test_case "slack multiple bindings require channel_id" `Quick
            test_slack_multiple_bindings_require_channel_id;
          test_case "slack foreign channel_id is an error" `Quick
            test_slack_foreign_channel_id_is_error;
          test_case "unsupported surfaces are errors" `Quick
            test_unsupported_surface_is_error;
        ] );
      ( "set_blocks",
        [
          test_case "attaches blocks to slack target" `Quick
            test_set_blocks_attaches_to_slack;
          test_case "ignores non-slack targets" `Quick
            test_set_blocks_ignores_other_targets;
        ] );
      ( "assistant append",
        [
          test_case "persists assistant line with source" `Quick
            test_assistant_message_persists_with_source;
        ] );
    ]
