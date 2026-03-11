(** Coverage tests for Tool_voice *)

open Alcotest

module Tool_voice = Masc_mcp.Tool_voice

let contains haystack needle =
  let text = String.lowercase_ascii haystack in
  let sub = String.lowercase_ascii needle in
  try
    ignore (Str.search_forward (Str.regexp_string sub) text 0);
    true
  with Not_found -> false

let with_ctx_no_net f =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let ctx : _ Tool_voice.context =
            {
              agent_name = "test-agent";
              sw;
              clock = Eio.Stdenv.clock env;
              net = None;
            }
          in
          f ctx))

let dispatch_exn ctx ~name ~args =
  match Tool_voice.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let json_field name json =
  match Yojson.Safe.from_string json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let test_dispatch_unknown () =
  with_ctx_no_net (fun ctx ->
      check bool "unknown returns None" true
        (Tool_voice.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) = None))

let test_dispatch_known_tools () =
  with_ctx_no_net (fun ctx ->
      let tools =
        [
          "masc_voice_speak";
          "masc_voice_session_start";
          "masc_voice_session_end";
          "masc_voice_sessions";
          "masc_voice_agent";
          "masc_voice_transcript";
          "masc_voice_conference_start";
          "masc_voice_conference_end";
        ]
      in
      List.iter
        (fun name ->
          check bool (name ^ " dispatches") true
            (Tool_voice.dispatch ctx ~name ~args:(`Assoc []) <> None))
        tools)

let test_voice_agent_uses_configured_voice () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_agent"
          ~args:(`Assoc [ ("agent_id", `String "claude") ])
      in
      check bool "ok" true ok;
      check (option string) "voice"
        (Some "Sarah")
        (match json_field "voice" body with Some (`String s) -> Some s | _ -> None))

let test_voice_speak_without_net_falls_back_to_text () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_speak"
          ~args:
            (`Assoc
              [
                ("agent_id", `String "gemini");
                ("message", `String "hello from voice");
              ])
      in
      check bool "ok" true ok;
      check (option string) "status"
        (Some "text_fallback")
        (match json_field "status" body with Some (`String s) -> Some s | _ -> None);
      check (option string) "voice"
        (Some "Roger")
        (match json_field "voice" body with Some (`String s) -> Some s | _ -> None))

let test_voice_session_start_without_net_errors () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_session_start"
          ~args:(`Assoc [ ("agent_id", `String "claude") ])
      in
      check bool "fails" false ok;
      check bool "mentions net" true (contains body "net"))

let test_voice_sessions_without_net_returns_empty_list () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_sessions" ~args:(`Assoc [])
      in
      check bool "ok" true ok;
      check (option string) "status"
        (Some "voice_server_unavailable")
        (match json_field "status" body with Some (`String s) -> Some s | _ -> None))

let test_voice_conference_end_without_net_returns_zero () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_conference_end"
          ~args:(`Assoc [ ("agent_ids", `List [ `String "claude"; `String "gemini" ]) ])
      in
      check bool "ok" true ok;
      check (option int) "ended"
        (Some 0)
        (match json_field "ended" body with Some (`Int n) -> Some n | _ -> None))

let () =
  run "Tool_voice"
    [
      ( "dispatch",
        [
          test_case "unknown" `Quick test_dispatch_unknown;
          test_case "known tools" `Quick test_dispatch_known_tools;
        ] );
      ( "handlers",
        [
          test_case "voice agent" `Quick test_voice_agent_uses_configured_voice;
          test_case "speak fallback" `Quick test_voice_speak_without_net_falls_back_to_text;
          test_case "session start no net" `Quick test_voice_session_start_without_net_errors;
          test_case "sessions no net" `Quick test_voice_sessions_without_net_returns_empty_list;
          test_case "conference end no net" `Quick test_voice_conference_end_without_net_returns_zero;
        ] );
    ]
