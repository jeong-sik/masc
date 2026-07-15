module K = Masc.Keeper_chat_store
module B = Masc.Keeper_chat_blocks
module MS = Masc.Keeper_world_observation_message_scope
module P = Masc.Otel_metric_store
module KT = Masc.Keeper_turn

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let temp_base_path prefix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let contains_substring haystack needle =
  String_util.contains_substring haystack needle

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs f

let secret_root_default ~base_dir ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "secrets")
    (Workspace_utils.safe_filename keeper_name)

let drop_value reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", "keeper_chat_store"); ("reason", reason)]
    ()

let chat_path ~base_dir ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ ("name", `String name)
         ; ("trace_id", `String ("test-trace-" ^ name))
         ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("meta_of_json failed: " ^ err)

let test_load_records_malformed_row_drops () =
  let base_dir = temp_base_path "keeper-chat-store-drops" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-drop" in
      let path = chat_path ~base_dir ~keeper_name in
      let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before_entry_error = drop_value entry_error in
      let before_invalid_payload = drop_value invalid_payload in
      write_file path
        (String.concat "\n"
           [
             Yojson.Safe.to_string
               (`Assoc
                  [
                    ("role", `String "user");
                    ("content", `String "hello");
                    ("ts", `Float 1.0);
                  ]);
             "{not-json";
             Yojson.Safe.to_string (`Assoc [("role", `String "assistant")]);
             Yojson.Safe.to_string
               (`Assoc
                  [
                    ("role", `String "assistant");
                    ("content", `String "world");
                    ("ts", `Float 2.0);
                  ]);
           ]
        ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "valid messages survive" 2 (List.length messages);
      Alcotest.(check (list string)) "content order"
        [ "hello"; "world" ]
        (List.map (fun (msg : K.chat_message) -> msg.content) messages);
      Alcotest.(check (float 0.001)) "malformed json increments entry error"
        1.0
        (drop_value entry_error -. before_entry_error);
      Alcotest.(check (float 0.001)) "missing content increments invalid payload"
        1.0
        (drop_value invalid_payload -. before_invalid_payload))

let roles messages =
  List.map (fun (m : K.chat_message) -> K.Role.to_label m.role) messages

let recent_roles lines =
  List.map
    (fun (line : MS.recent_direct_line) ->
      MS.direct_line_role_to_label line.role)
    lines

let test_append_turn_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-turn" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-turn" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"run the checks"
        ~user_attachments:[]
        ~tool_calls:
          [
            { K.call_id = "toolu_1"; call_name = "Read"; args = {|{"path":"x"}|} };
            (* Empty args normalise to "{}", empty id to a positional one. *)
            { K.call_id = ""; call_name = "masc_status"; args = "  " };
          ]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~assistant_content:"all green"
        ();
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "turn line order"
        [ "user"; "tool"; "tool"; "assistant" ]
        (roles messages);
      let tool1 = List.nth messages 1 in
      let tool2 = List.nth messages 2 in
      let asst = List.nth messages 3 in
      Alcotest.(check (option string)) "tool id persisted"
        (Some "toolu_1") tool1.tool_call_id;
      Alcotest.(check (option string)) "tool name persisted"
        (Some "Read") tool1.tool_call_name;
      Alcotest.(check string) "tool args persisted" {|{"path":"x"}|} tool1.content;
      Alcotest.(check (option string)) "empty tool id gets positional fallback"
        (Some "tc-1") tool2.tool_call_id;
      Alcotest.(check string) "empty args normalised" "{}" tool2.content;
      Alcotest.(check (option string)) "source persisted on every line"
        (Some "dashboard") asst.source;
      Alcotest.(check (option string)) "assistant has no tool id"
        None asst.tool_call_id)

let test_legacy_lines_parse_without_new_fields () =
  let base_dir = temp_base_path "keeper-chat-store-legacy" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-legacy" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"user","content":"hello","ts":1.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"world","ts":1.0}|} ^ "\n");
      match K.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
          Alcotest.(check (option string)) "legacy user has no source" None user.source;
          Alcotest.(check (option string)) "legacy assistant has no tool id"
            None assistant.tool_call_id
      | messages ->
          Alcotest.failf "expected 2 messages, got %d" (List.length messages))

(* R3: every persisted row carries a producer-assigned id that is
   non-empty, unique within a turn, and stable across reloads. *)
let test_message_id_minted_unique_and_stable () =
  let base_dir = temp_base_path "keeper-chat-store-id" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-id" in
      K.append_turn ~base_dir ~keeper_name ~user_content:"run the checks"
        ~user_attachments:[] ~assistant_content:"all green" ();
      let ids_of () =
        List.map (fun (m : K.chat_message) -> m.id) (K.load ~base_dir ~keeper_name)
      in
      let ids = ids_of () in
      List.iter
        (fun id ->
          Alcotest.(check bool) "row id is non-empty" true (String.length id > 0))
        ids;
      Alcotest.(check int) "ids are unique across the turn" (List.length ids)
        (List.length (List.sort_uniq String.compare ids));
      Alcotest.(check (list string)) "ids stable across reloads" ids (ids_of ()))

(* R3: rows written before the id field load with a deterministic id
   derived at the read boundary, so it is stable across reloads and two
   distinct rows get distinct ids — no index-derived synthesis. *)
let test_legacy_row_gets_deterministic_id () =
  let base_dir = temp_base_path "keeper-chat-store-legacy-id" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-legacy-id" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"user","content":"hello","ts":1.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"world","ts":1.0}|} ^ "\n");
      let ids_of () =
        List.map (fun (m : K.chat_message) -> m.id) (K.load ~base_dir ~keeper_name)
      in
      let first = ids_of () in
      Alcotest.(check int) "two legacy rows loaded" 2 (List.length first);
      List.iter
        (fun id ->
          Alcotest.(check bool) "legacy id non-empty" true (String.length id > 0))
        first;
      Alcotest.(check (list string)) "legacy ids deterministic across reloads"
        first (ids_of ());
      match first with
      | [ a; b ] ->
          Alcotest.(check bool) "distinct legacy rows get distinct ids" true (a <> b)
      | _ -> Alcotest.fail "expected 2 legacy ids")

(* R3: the /chat/history payload surfaces the id so the dashboard keys off
   it instead of synthesising one. *)
let test_to_json_array_exposes_id () =
  let base_dir = temp_base_path "keeper-chat-store-id-json" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-id-json" in
      K.append_user_message ~base_dir ~keeper_name ~content:"hi" ();
      match K.to_json_array (K.load ~base_dir ~keeper_name) with
      | `List (`Assoc fields :: _) ->
          Alcotest.(check bool) "payload row carries an id" true
            (List.mem_assoc "id" fields)
      | _ -> Alcotest.fail "expected a non-empty json array of assoc rows")

let test_recent_direct_context_renders_prior_reply_and_tool_evidence () =
  let base_dir = temp_base_path "keeper-chat-recent-context" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-recent-context" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"what were you doing"
        ~user_attachments:[]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~assistant_content:"I was reading the board."
        ();
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"what did you actually check"
        ~user_attachments:[]
        ~tool_calls:
          [ { K.call_id = "toolu_board";
              call_name = "keeper_board_list";
              args = {|{"limit":20}|} } ]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~assistant_content:"This time I checked the board list."
        ();
      let lines =
        K.load ~base_dir ~keeper_name
        |> MS.recent_direct_conversation_of_messages ~limit:4
      in
      Alcotest.(check (list string)) "bounded tail keeps prior reply and tool"
        [ "assistant"; "user"; "tool_call"; "assistant" ]
        (recent_roles lines);
      let rendered = MS.render_recent_direct_conversation_context lines in
      Alcotest.(check bool) "previous assistant utterance is visible" true
        (contains_substring rendered "I was reading the board.");
      Alcotest.(check bool) "tool evidence keeps only call name" true
        (contains_substring rendered "tool_call: keeper_board_list");
      Alcotest.(check bool) "tool args are not prompt evidence" false
        (contains_substring rendered {|{"limit":20}|});
      Alcotest.(check bool) "grounding guard present" true
        (contains_substring rendered "without tool evidence"))

let test_recent_direct_context_omits_transport_failure_as_self_reply () =
  let base_dir = temp_base_path "keeper-chat-recent-failure" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-recent-failure" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"please answer this"
        ~user_attachments:[]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~assistant_kind:K.Row_kind.Transport_failure
        ~assistant_content:"Keeper request failed: timeout"
        ();
      let lines =
        K.load ~base_dir ~keeper_name
        |> MS.recent_direct_conversation_of_messages
      in
      Alcotest.(check (list string)) "failed request keeps user only"
        [ "user" ] (recent_roles lines);
      let rendered = MS.render_recent_direct_conversation_context lines in
      Alcotest.(check bool) "failure text is not a self utterance" false
        (contains_substring rendered "Keeper request failed"))

let test_recent_direct_context_omits_voice_audio_self_echo () =
  let base_dir = temp_base_path "keeper-chat-recent-voice" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-recent-voice" in
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:"I will say this out loud now."
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~audio:
          { K.token = "voice-token-1"
          ; audio_url = None
          ; mime = "audio/mpeg"
          ; duration_sec = None
          ; message_text = "I will say this out loud now."
          ; device_id = None
          ; expired = false
          }
        ();
      let lines =
        K.load ~base_dir ~keeper_name
        |> MS.recent_direct_conversation_of_messages
      in
      Alcotest.(check (list string)) "voice self-output is not prompt context"
        [] (recent_roles lines);
      let rendered = MS.render_recent_direct_conversation_context lines in
      Alcotest.(check bool) "spoken text is not re-injected" false
        (contains_substring rendered "I will say this out loud now."))

let test_direct_owner_context_excludes_connector_turns () =
  with_eio_fs (fun () ->
    let base_dir = temp_base_path "keeper-chat-direct-owner-gate" in
    Fun.protect
      ~finally:(fun () -> try remove_tree base_dir with _ -> ())
      (fun () ->
        let meta = make_meta "keeper-chat-direct-owner-gate" in
        let keeper_name = meta.name in
        K.append_turn ~base_dir ~keeper_name
          ~user_content:"what did you just say"
          ~user_attachments:[]
          ~surface:(Surface_ref.Dashboard { session_id = None })
          ~assistant_content:"I just answered from direct chat."
          ();
        let config = Masc.Workspace.default_config base_dir in
        let context ?channel_session_key ~direct_reply ~channel () =
          KT.For_testing.direct_owner_conversation_context
            ~config ~meta ~direct_reply ~channel_session_key ~channel
        in
        let owner_context = context ~direct_reply:true ~channel:"" () in
        Alcotest.(check bool) "owner direct receives recent transcript" true
          (contains_substring
             owner_context
             "I just answered from direct chat.");
        Alcotest.(check string) "connector channel suppresses transcript" ""
          (context ~direct_reply:true ~channel:"discord" ());
        Alcotest.(check string) "connector session suppresses transcript" ""
          (context ~direct_reply:true ~channel:""
             ~channel_session_key:"discord_workspace" ());
        Alcotest.(check string) "non-direct turn suppresses transcript" ""
          (context ~direct_reply:false ~channel:"" ())))

let test_append_turn_redacts_projected_secrets () =
  let base_dir = temp_base_path "keeper-chat-store-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let env_secret = "chat.secret!" in
      let file_secret = "file.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN")
        (env_secret ^ "\n");
      write_file
        (Filename.concat (Filename.concat root "files") "home/keeper/key")
        file_secret;
      K.append_turn ~base_dir ~keeper_name
        ~user_content:("use " ^ env_secret)
        ~user_attachments:
          [ { K.id = "att-1";
              att_type = "text";
              name = "secret.txt";
              size = String.length file_secret;
              mime_type = "text/plain";
              data = file_secret } ]
        ~tool_calls:
          [ { K.call_id = "toolu_1";
              call_name = "keeper_exec";
              args = {|{"token":"|} ^ env_secret ^ {|"}|} } ]
        ~assistant_content:("done " ^ file_secret)
        ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "env secret not persisted" false
        (contains_substring raw env_secret);
      Alcotest.(check bool) "file secret not persisted" false
        (contains_substring raw file_secret);
      let messages = K.load ~base_dir ~keeper_name in
      let rendered = Yojson.Safe.to_string (K.to_json_array messages) in
      Alcotest.(check bool) "loaded view stays redacted" false
        (contains_substring rendered env_secret);
      Alcotest.(check bool) "redaction marker present" true
        (contains_substring rendered "[REDACTED]"))

let test_load_redacts_legacy_raw_secret_rows () =
  let base_dir = temp_base_path "keeper-chat-store-read-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-read-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "legacy.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        (Yojson.Safe.to_string
           (`Assoc
              [ ("role", `String "assistant");
                ("content", `String ("old row " ^ secret));
                ("ts", `Float 1.0) ])
         ^ "\n");
      match K.load ~base_dir ~keeper_name with
      | [ msg ] ->
          Alcotest.(check bool) "legacy raw value hidden on read" false
            (contains_substring msg.K.content secret);
          Alcotest.(check bool) "marker present on read" true
            (contains_substring msg.K.content "[REDACTED]")
      | messages ->
          Alcotest.failf "expected 1 message, got %d" (List.length messages))

(* RFC-0223 P1 — speaker identity round-trips on the user line only. *)

let speaker_label (msg : K.chat_message) =
  match msg.speaker with
  | None -> "absent"
  | Some sp -> K.authority_label sp.speaker_authority

let test_speaker_external_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-speaker-ext" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-speaker-ext" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"hello from discord"
        ~user_attachments:[]
        ~surface:(Surface_ref.Gate { label = "discord"; address = [] })
        ~speaker:
          { K.speaker_id = Some "98791450001";
            speaker_name = Some "minsu";
            speaker_authority = K.External }
        ~assistant_content:"hi minsu"
        ();
      match K.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
          (match user.speaker with
           | Some sp ->
               Alcotest.(check (option string)) "speaker id persisted"
                 (Some "98791450001") sp.K.speaker_id;
               Alcotest.(check (option string)) "speaker name persisted"
                 (Some "minsu") sp.K.speaker_name;
               Alcotest.(check string) "authority external"
                 "external" (K.authority_label sp.K.speaker_authority)
           | None -> Alcotest.fail "user line lost its speaker");
          Alcotest.(check string) "assistant line carries no speaker"
            "absent" (speaker_label assistant)
      | messages ->
          Alcotest.failf "expected 2 messages, got %d" (List.length messages))

(* RFC-0226: an inbound line recorded at delivery time stands alone —
   no paired assistant turn — and a later reply-path assistant append
   joins it on the same lane without duplicating the user line. *)
let test_append_user_message_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-ambient" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-ambient" in
      K.append_user_message ~base_dir ~keeper_name
        ~content:"two humans chatting, no mention"
        ~surface:(Surface_ref.Gate { label = "discord"; address = [] })
        ~conversation_id:"discord:guild-1:channel:chan-7"
        ~external_message_id:"msg-7"
        ~speaker:
          { K.speaker_id = Some "55501";
            speaker_name = Some "jane";
            speaker_authority = K.External }
        ();
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:"reply recorded separately"
        ~surface:(Surface_ref.Gate { label = "discord"; address = [] })
        ~conversation_id:"discord:guild-1:channel:chan-7" ();
      match K.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
          Alcotest.(check string) "lone user line first" "user" (K.Role.to_label user.K.role);
          Alcotest.(check string) "content"
            "two humans chatting, no mention" user.K.content;
          Alcotest.(check (option string)) "source"
            (Some "discord") user.K.source;
          Alcotest.(check (option string)) "conversation id"
            (Some "discord:guild-1:channel:chan-7") user.K.conversation_id;
          Alcotest.(check (option string)) "external message id"
            (Some "msg-7") user.K.external_message_id;
          (match user.speaker with
           | Some sp ->
               Alcotest.(check (option string)) "speaker id"
                 (Some "55501") sp.K.speaker_id;
               Alcotest.(check (option string)) "speaker name"
                 (Some "jane") sp.K.speaker_name;
               Alcotest.(check string) "authority external"
                 "external" (K.authority_label sp.K.speaker_authority)
           | None -> Alcotest.fail "ambient user line lost its speaker");
          Alcotest.(check string) "assistant joins the lane"
            "assistant" (K.Role.to_label assistant.K.role);
          Alcotest.(check (option string)) "assistant conversation id"
            (Some "discord:guild-1:channel:chan-7") assistant.K.conversation_id;
          Alcotest.(check (option string)) "assistant has no inbound message id"
            None assistant.K.external_message_id;
          Alcotest.(check string) "no duplicated user line"
            "reply recorded separately" assistant.K.content;
          let json_rows = K.to_json_array [ user; assistant ] in
          (match Yojson.Safe.Util.to_list json_rows with
          | user_json :: assistant_json :: _ ->
              Alcotest.(check string) "json conversation id"
                "discord:guild-1:channel:chan-7"
                Yojson.Safe.Util.(
                  user_json |> member "conversation_id" |> to_string);
              Alcotest.(check string) "json external message id" "msg-7"
                Yojson.Safe.Util.(
                  user_json |> member "external_message_id" |> to_string);
              Alcotest.(check string) "json assistant conversation id"
                "discord:guild-1:channel:chan-7"
                Yojson.Safe.Util.(
                  assistant_json |> member "conversation_id" |> to_string);
              Alcotest.(check bool) "json assistant omits inbound message id" true
                Yojson.Safe.Util.(
                  assistant_json |> member "external_message_id" = `Null);
              (* RFC-0232 P5: the structured surface must survive the
                 read-serve emitter, not only the derived [source] label, so
                 the dashboard rebuilds the connector deep-link on a history
                 reload instead of dropping it. *)
              let user_surface = Yojson.Safe.Util.member "surface" user_json in
              Alcotest.(check bool) "json user row carries structured surface"
                true (user_surface <> `Null);
              (match Surface_ref.of_json user_surface with
               | Ok s ->
                   Alcotest.(check string)
                     "surface round-trips to the discord gate lane" "discord"
                     (Surface_ref.lane_label s)
               | Error e ->
                   Alcotest.failf "surface did not round-trip from json: %s" e)
          | rows ->
              Alcotest.failf "expected 2 json rows, got %d"
                (List.length rows))
      | messages ->
          Alcotest.failf "expected 2 messages, got %d" (List.length messages))

let test_speaker_owner_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-speaker-own" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-speaker-own" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"deploy it"
        ~user_attachments:[]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~speaker:
          { K.speaker_id = None;
            speaker_name = None;
            speaker_authority = K.Owner }
        ~assistant_content:"deploying"
        ();
      match K.load ~base_dir ~keeper_name with
      | [ user; _assistant ] -> (
          match user.speaker with
          | Some sp ->
              Alcotest.(check (option string)) "owner has no id"
                None sp.K.speaker_id;
              Alcotest.(check string) "authority owner"
                "owner" (K.authority_label sp.K.speaker_authority)
          | None -> Alcotest.fail "owner speaker lost")
      | messages ->
          Alcotest.failf "expected 2 messages, got %d" (List.length messages))

let test_unknown_speaker_authority_reported_not_guessed () =
  let base_dir = temp_base_path "keeper-chat-store-speaker-bad" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-speaker-bad" in
      let path = chat_path ~base_dir ~keeper_name in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      write_file path
        ({|{"role":"user","content":"hi","ts":1.0,"speaker_id":"x","speaker_authority":"admin"}|}
        ^ "\n");
      (match K.load ~base_dir ~keeper_name with
       | [ user ] ->
           Alcotest.(check string)
             "unknown authority yields no speaker, row kept"
             "absent" (speaker_label user)
       | messages ->
           Alcotest.failf "expected 1 message, got %d" (List.length messages));
      Alcotest.(check (float 0.001)) "unknown authority counted as drop"
        1.0
        (drop_value invalid_payload -. before))

let test_unknown_role_row_dropped () =
  (* RFC-0232 P1: a role label outside the closed sum cannot participate
     in lane semantics; the row is dropped and reported, never defaulted. *)
  let base_dir = temp_base_path "keeper-chat-store-role-bad" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-role-bad" in
      let path = chat_path ~base_dir ~keeper_name in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      write_file path
        ({|{"role":"user","content":"hi","ts":1.0}|} ^ "\n"
        ^ {|{"role":"system","content":"injected","ts":2.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"done","ts":3.0}|} ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "unknown role row dropped"
        [ "user"; "assistant" ] (roles messages);
      Alcotest.(check (float 0.001)) "drop counted as invalid payload"
        1.0
        (drop_value invalid_payload -. before))

let test_tool_row_missing_name_dropped () =
  let base_dir = temp_base_path "keeper-chat-store-toolname" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-toolname" in
      let path = chat_path ~base_dir ~keeper_name in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      write_file path
        ({|{"role":"user","content":"hi","ts":1.0}|} ^ "\n"
        ^ {|{"role":"tool","content":"{}","ts":1.0,"tool_call_id":"toolu_9"}|} ^ "\n"
        ^ {|{"role":"assistant","content":"done","ts":1.0}|} ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "nameless tool row dropped"
        [ "user"; "assistant" ] (roles messages);
      Alcotest.(check (float 0.001)) "drop counted as invalid payload"
        1.0
        (drop_value invalid_payload -. before))

let test_window_keeps_tool_lines_of_retained_turns () =
  let base_dir = temp_base_path "keeper-chat-store-window" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-window" in
      (* 51 turns of (user, tool, assistant) = 102 primaries; the window
         keeps the last 100 primaries (50 full turns) and trims the
         leading turn's orphaned tool line. *)
      for i = 1 to 51 do
        K.append_turn ~base_dir ~keeper_name
          ~user_content:(Printf.sprintf "u%d" i)
          ~user_attachments:[]
          ~tool_calls:
            [ { K.call_id = Printf.sprintf "t%d" i; call_name = "Read"; args = "{}" } ]
          ~assistant_content:(Printf.sprintf "a%d" i)
          ()
      done;
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "50 full turns survive" 150 (List.length messages);
      let primaries =
        List.filter (fun (m : K.chat_message) -> not (K.Role.equal m.role K.Role.Tool)) messages
      in
      Alcotest.(check int) "primary window is 100" 100 (List.length primaries);
      match messages with
      | first :: _ ->
          Alcotest.(check string) "window starts at a user line, not an orphan tool"
            "user" (K.Role.to_label first.role);
          Alcotest.(check string) "oldest retained turn is turn 2" "u2" first.content
      | [] -> Alcotest.fail "expected non-empty window")

let test_orphan_leading_tool_lines_trimmed () =
  let base_dir = temp_base_path "keeper-chat-store-orphan" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-orphan" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"tool","content":"{}","ts":1.0,"tool_call_id":"t0","tool_call_name":"Read"}|}
         ^ "\n"
        ^ {|{"role":"user","content":"hi","ts":2.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"yo","ts":2.0}|} ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "leading orphan tool trimmed"
        [ "user"; "assistant" ] (roles messages))

(* RFC-0226 P2: a lane larger than the tail-read bound must still
   yield exactly the window a full scan would — the bound only caps
   bytes read, never changes window semantics. 5,200 x ~1 KiB lines
   ≈ 5.3 MiB > the 4 MiB tail bound, so [load] starts mid-file. *)
let test_tail_bounded_load_matches_full_scan_window () =
  let base_dir = temp_base_path "keeper-chat-store-tail" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-tail" in
      let path = chat_path ~base_dir ~keeper_name in
      let padding = String.make 1000 'x' in
      let total = 5200 in
      let buf = Buffer.create (total * 1100) in
      for i = 1 to total do
        let role = if i mod 2 = 1 then "user" else "assistant" in
        let line =
          Yojson.Safe.to_string
            (`Assoc
               [ ("role", `String role);
                 ("content", `String (Printf.sprintf "msg-%04d %s" i padding));
                 ("ts", `Float (float_of_int i));
               ])
        in
        Buffer.add_string buf line;
        Buffer.add_char buf '\n'
      done;
      write_file path (Buffer.contents buf);
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "window is 100 primaries" 100 (List.length messages);
      let content_prefix (m : K.chat_message) = String.sub m.K.content 0 8 in
      (match messages with
       | first :: _ ->
           Alcotest.(check string) "window starts at line 5101"
             "msg-5101" (content_prefix first);
           Alcotest.(check string) "line 5101 is a user line" "user" (K.Role.to_label first.K.role)
       | [] -> Alcotest.fail "expected non-empty window");
      (match List.rev messages with
       | last :: _ ->
           Alcotest.(check string) "window ends at line 5200"
             "msg-5200" (content_prefix last);
           Alcotest.(check string) "line 5200 is an assistant line"
             "assistant" (K.Role.to_label last.K.role)
       | [] -> Alcotest.fail "expected non-empty window"))

(* RFC-0228 P1 — backward paging. Raw JSONL with controlled ts so the
   page boundaries are exact. *)
let write_numbered_lane ~path ~total ~pad_bytes =
  let padding = String.make pad_bytes 'x' in
  let buf = Buffer.create (total * (pad_bytes + 80)) in
  for i = 1 to total do
    Buffer.add_string buf
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("role", `String (if i mod 2 = 1 then "user" else "assistant"));
              ("content", `String (Printf.sprintf "msg-%04d %s" i padding));
              ("ts", `Float (float_of_int i));
            ]));
    Buffer.add_char buf '\n'
  done;
  write_file path (Buffer.contents buf)

let content_no (m : K.chat_message) =
  int_of_string (String.sub m.K.content 4 4)

let test_load_page_walks_backward_small_file () =
  let base_dir = temp_base_path "keeper-chat-store-page-small" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-page-small" in
      write_numbered_lane
        ~path:(chat_path ~base_dir ~keeper_name)
        ~total:300 ~pad_bytes:0;
      (* Page 1: strictly older than ts 250 → window 150..249. *)
      let p1 = K.load_page ~base_dir ~keeper_name ~before:250.0 () in
      Alcotest.(check int) "window size" 100 (List.length p1.K.messages);
      Alcotest.(check int) "first" 150 (content_no (List.hd p1.K.messages));
      Alcotest.(check int) "last" 249
        (content_no (List.hd (List.rev p1.K.messages)));
      Alcotest.(check bool) "older rows remain" true p1.K.has_more;
      (* Page 2: walk with the oldest returned ts. *)
      let p2 = K.load_page ~base_dir ~keeper_name ~before:150.0 () in
      Alcotest.(check int) "page2 first" 50 (content_no (List.hd p2.K.messages));
      (* Final page: fewer rows than the window, nothing older. *)
      let p3 = K.load_page ~base_dir ~keeper_name ~before:50.0 () in
      Alcotest.(check int) "page3 size" 49 (List.length p3.K.messages);
      Alcotest.(check int) "page3 first" 1 (content_no (List.hd p3.K.messages));
      Alcotest.(check bool) "history exhausted" false p3.K.has_more;
      (* before older than everything → empty, exhausted. *)
      let p4 = K.load_page ~base_dir ~keeper_name ~before:1.0 () in
      Alcotest.(check int) "empty page" 0 (List.length p4.K.messages);
      Alcotest.(check bool) "empty page exhausted" false p4.K.has_more)

let test_load_page_binary_search_large_file () =
  let base_dir = temp_base_path "keeper-chat-store-page-large" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-page-large" in
      (* ~5.3 MiB: larger than both the 4 MiB window slice and the
         256 KiB probe, so find_cut's loop actually narrows. *)
      write_numbered_lane
        ~path:(chat_path ~base_dir ~keeper_name)
        ~total:5200 ~pad_bytes:1000;
      let p = K.load_page ~base_dir ~keeper_name ~before:5000.0 () in
      Alcotest.(check int) "window size" 100 (List.length p.K.messages);
      Alcotest.(check int) "first" 4900 (content_no (List.hd p.K.messages));
      Alcotest.(check int) "last" 4999
        (content_no (List.hd (List.rev p.K.messages)));
      Alcotest.(check bool) "older rows remain" true p.K.has_more;
      (* Tail mode on the same file reports more history too. *)
      let tail = K.load_page ~base_dir ~keeper_name () in
      Alcotest.(check int) "tail last" 5200
        (content_no (List.hd (List.rev tail.K.messages)));
      Alcotest.(check bool) "tail has_more" true tail.K.has_more)

(* ── Row_kind (typed transport-failure marker) ───────────── *)

let test_failure_turn_kind_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-kind" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-kind" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"ping"
        ~user_attachments:[]
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~assistant_kind:K.Row_kind.Transport_failure
        ~assistant_content:"Keeper request failed: boom"
        ();
      match K.load ~base_dir ~keeper_name with
      | [ user; asst ] ->
          Alcotest.(check bool) "user row is an utterance" true
            (K.Row_kind.equal user.kind K.Row_kind.Utterance);
          Alcotest.(check bool) "assistant row is a transport failure" true
            (K.Row_kind.equal asst.kind K.Row_kind.Transport_failure);
          let raw = read_file (chat_path ~base_dir ~keeper_name) in
          Alcotest.(check bool) "failure row persists the kind field" true
            (contains_substring raw {|"kind":"transport_failure"|})
      | messages ->
          Alcotest.failf "expected 2 rows, got %d" (List.length messages))

let test_kind_absent_reads_utterance () =
  (* Every row written before the [kind] field existed is an utterance;
     the writer also omits the field for utterances, so ordinary rows
     stay byte-identical to the pre-[kind] format. *)
  let base_dir = temp_base_path "keeper-chat-store-kind-absent" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-kind-absent" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"hello" ~user_attachments:[]
        ~assistant_content:"world" ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "utterance rows carry no kind field" false
        (contains_substring raw {|"kind"|});
      match K.load ~base_dir ~keeper_name with
      | [ user; asst ] ->
          Alcotest.(check bool) "user reads as utterance" true
            (K.Row_kind.equal user.kind K.Row_kind.Utterance);
          Alcotest.(check bool) "assistant reads as utterance" true
            (K.Row_kind.equal asst.kind K.Row_kind.Utterance)
      | messages ->
          Alcotest.failf "expected 2 rows, got %d" (List.length messages))

let test_unknown_kind_reported_reads_utterance () =
  let base_dir = temp_base_path "keeper-chat-store-kind-unknown" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-kind-unknown" in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"assistant","content":"hi","ts":1.0,"kind":"weird"}|} ^ "\n");
      match K.load ~base_dir ~keeper_name with
      | [ asst ] ->
          Alcotest.(check bool)
            "unknown kind reads as utterance (conservative arm)" true
            (K.Row_kind.equal asst.kind K.Row_kind.Utterance);
          Alcotest.(check (float 0.001)) "unknown kind reported" 1.0
            (drop_value invalid_payload -. before)
      | messages ->
          Alcotest.failf "expected 1 row, got %d" (List.length messages))

let audio_path ~base_dir token =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    (token ^ ".mp3")

let json_audio_expired = function
  | `Assoc fields -> (
      match List.assoc_opt "audio" fields with
      | Some (`Assoc audio_fields) -> (
          match List.assoc_opt "expired" audio_fields with
          | Some (`Bool b) -> b
          | _ -> false)
      | _ -> false)
  | _ -> false

(* RFC-0235 P3: the history endpoint marks audio clips as expired when the
   underlying MP3 has been reaped, so the dashboard can show a fallback
   instead of a broken native player. *)
let test_audio_clip_marked_expired_when_file_missing () =
  let base_dir = temp_base_path "keeper-chat-store-audio-expired" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-audio-expired" in
      let token = "voice-token-missing" in
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:"I will say this out loud now."
        ~surface:(Surface_ref.Dashboard { session_id = None })
        ~audio:
          { K.token
          ; audio_url = None
          ; mime = "audio/mpeg"
          ; duration_sec = None
          ; message_text = "I will say this out loud now."
          ; device_id = None
          ; expired = false
          }
        ();
      let messages = K.load ~base_dir ~keeper_name in
      let rows = Yojson.Safe.Util.to_list (K.to_json_array ~base_dir messages) in
      Alcotest.(check int) "one json row" 1 (List.length rows);
      Alcotest.(check bool) "missing file marks clip expired" true
        (json_audio_expired (List.hd rows));
      (* Create the file and reload: the clip is no longer expired. *)
      let path = audio_path ~base_dir token in
      mkdir_p (Filename.dirname path);
      write_file path "mp3-bytes";
      let rows_present = Yojson.Safe.Util.to_list (K.to_json_array ~base_dir messages) in
      Alcotest.(check bool) "present file does not mark expired" false
        (json_audio_expired (List.hd rows_present)))

let test_audio_clip_expired_persists_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-audio-expired-rt" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-audio-expired-rt" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"assistant","content":"hello","ts":1.0,"audio":{|}
        ^ {|"token":"voice-token-rt","mime":"audio/mpeg","message_text":"hello","expired":true}|}
        ^ "}\n");
      match K.load ~base_dir ~keeper_name with
      | [ msg ] -> (
          match msg.K.audio with
          | Some a ->
              Alcotest.(check bool) "expired flag round-trips" true a.K.expired
          | None -> Alcotest.fail "audio field missing")
      | messages ->
          Alcotest.failf "expected 1 row, got %d" (List.length messages))

let test_audio_url_and_device_id_persist () =
  let base_dir = temp_base_path "keeper-chat-store-audio-url" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-audio-url" in
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:"voice line"
        ~audio:
          { K.token = "voice-token-url"
          ; audio_url = Some "https://example.com/audio.mp3"
          ; mime = "audio/mpeg"
          ; duration_sec = Some 1.5
          ; message_text = "voice line"
          ; device_id = Some "device-42"
          ; expired = false
          }
        ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "audio_url persisted"
        true
        (contains_substring raw "\"audio_url\":\"https://example.com/audio.mp3\"");
      Alcotest.(check bool) "device_id persisted"
        true
        (contains_substring raw "\"device_id\":\"device-42\"");
      let messages = K.load ~base_dir ~keeper_name in
      match K.to_json_array messages with
      | `List [ `Assoc fields ] -> (
          match List.assoc_opt "audio" fields with
          | Some (`Assoc audio_fields) ->
              Alcotest.(check (option string)) "audio_url round-trips"
                (Some "https://example.com/audio.mp3")
                (Option.bind (List.assoc_opt "audio_url" audio_fields) (function
                   | `String s -> Some s | _ -> None));
              Alcotest.(check (option string)) "device_id round-trips"
                (Some "device-42")
                (Option.bind (List.assoc_opt "device_id" audio_fields) (function
                   | `String s -> Some s | _ -> None))
          | _ -> Alcotest.fail "audio field missing or malformed")
      | _ -> Alcotest.fail "expected one json row")

let test_invalid_audio_token_treated_as_expired () =
  let base_dir = temp_base_path "keeper-chat-store-audio-token" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-audio-token" in
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:"voice line"
        ~audio:
          { K.token = "../../../etc/passwd"
          ; audio_url = None
          ; mime = "audio/mpeg"
          ; duration_sec = None
          ; message_text = "voice line"
          ; device_id = None
          ; expired = false
          }
        ();
      let messages = K.load ~base_dir ~keeper_name in
      let rows = Yojson.Safe.Util.to_list (K.to_json_array ~base_dir messages) in
      Alcotest.(check int) "one json row" 1 (List.length rows);
      Alcotest.(check bool) "invalid token marks clip expired" true
        (json_audio_expired (List.hd rows)))

(* RFC-0235 P3: backend-driven rich chat blocks. *)

let json_blocks = function
  | `Assoc fields -> (
      match List.assoc_opt "blocks" fields with
      | Some (`List items) -> Some items
      | _ -> None)
  | _ -> None

let test_assistant_row_gets_backend_blocks () =
  let base_dir = temp_base_path "keeper-chat-store-blocks" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-blocks" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"show me"
        ~user_attachments:[]
        ~assistant_content:"Here is the shot.\n\n![shot](https://x.com/screen.png)\n\nSee https://x.com/post for context."
        ();
      let messages = K.load ~base_dir ~keeper_name in
      let asst = List.find (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.Assistant) messages in
      Alcotest.(check bool) "assistant has blocks" true
        (Option.is_some asst.K.blocks);
      let rows = Yojson.Safe.Util.to_list (K.to_json_array messages) in
      let asst_json = List.find (fun row ->
        match row with
        | `Assoc fields -> (
            match List.assoc_opt "role" fields with
            | Some (`String "assistant") -> true
            | _ -> false)
        | _ -> false) rows in
      match json_blocks asst_json with
      | Some items -> Alcotest.(check int) "blocks serialized" 3 (List.length items)
      | None -> Alcotest.fail "assistant json missing blocks")

let test_user_and_tool_rows_have_no_blocks () =
  let base_dir = temp_base_path "keeper-chat-store-blocks-no-user" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-blocks-no-user" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"https://x.com/post"
        ~user_attachments:[]
        ~tool_calls:[ { K.call_id = "t1"; call_name = "Read"; args = "{}" } ]
        ~assistant_content:"done"
        ();
      let messages = K.load ~base_dir ~keeper_name in
      let user = List.find (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.User) messages in
      let tool = List.find (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.Tool) messages in
      Alcotest.(check bool) "user row has no blocks" true (user.K.blocks = None);
      Alcotest.(check bool) "tool row has no blocks" true (tool.K.blocks = None))

let test_blocks_roundtrip_and_drop_malformed () =
  let base_dir = temp_base_path "keeper-chat-store-blocks-rt" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-blocks-rt" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"assistant","content":"hello","ts":1.0,"blocks":[{|}
        ^ {|"t":"p","html":"hello"},{"t":"image","src":"https://x.com/a.png","cap":"a"},{|}
        ^ {|"t":"link","url":"https://x.com","title":"x.com","meta":"x.com"},{|}
        ^ {|"t":"unknown","x":1}]}|}
        ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      match messages with
      | [ msg ] -> (
          match msg.K.blocks with
          | Some blocks -> Alcotest.(check int) "valid blocks kept, malformed dropped" 3 (List.length blocks)
          | None -> Alcotest.fail "blocks missing")
      | messages -> Alcotest.failf "expected 1 row, got %d" (List.length messages))

let test_append_turn_redacts_supplied_thinking_blocks () =
  let base_dir = temp_base_path "keeper-chat-store-thinking-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-thinking-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "thinking.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      K.append_turn
        ~base_dir
        ~keeper_name
        ~user_content:"think"
        ~user_attachments:[]
        ~assistant_content:"done"
        ~blocks:
          [ B.Thinking
              { content = "private reasoning uses " ^ secret; redacted = false }
          ]
        ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "thinking secret not persisted" false
        (contains_substring raw secret);
      Alcotest.(check bool) "redaction marker persisted" true
        (contains_substring raw "[REDACTED]");
      let messages = K.load ~base_dir ~keeper_name in
      let assistant =
        List.find
          (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.Assistant)
          messages
      in
      match assistant.K.blocks with
      | Some [ B.Thinking thinking ] ->
        Alcotest.(check bool) "thinking content redacted on load" false
          (contains_substring thinking.content secret);
        Alcotest.(check bool) "thinking redaction marker visible" true
          (contains_substring thinking.content "[REDACTED]")
      | Some _ -> Alcotest.fail "expected exactly one thinking block"
      | None -> Alcotest.fail "assistant thinking block missing")

let test_append_turn_redacts_all_supplied_block_strings () =
  let base_dir = temp_base_path "keeper-chat-store-rich-block-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-rich-block-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "rich-block.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      K.append_turn
        ~base_dir
        ~keeper_name
        ~user_content:"render"
        ~user_attachments:[]
        ~assistant_content:"done"
        ~blocks:
          [ B.Code
              { cap = Some ("shell " ^ secret)
              ; html = "echo " ^ secret
              ; source = Some ("source " ^ secret)
              }
          ; B.Mermaid
              { source = "graph TD\nA[" ^ secret ^ "]"
              ; caption = Some ("flow " ^ secret)
              }
          ; B.Trace
              { trace =
                  [ B.Trace_think
                      { text = "thinking " ^ secret
                      ; ts = Some ("ts-" ^ secret)
                      ; oas_block_index = None
                      }
                  ; B.Trace_reason
                      { text = "reason " ^ secret
                      ; detail = Some ("detail " ^ secret)
                      ; ts = None
                      }
                  ; B.Trace_tool
                      { name = "tool " ^ secret
                      ; tool_call_id = Some ("call " ^ secret)
                      ; status = Some B.Trace_tool_err
                      ; dur = Some ("dur " ^ secret)
                      ; args =
                          Some
                            (`Assoc
                              [ "token", `String secret
                              ; "api_token", `String "plain-non-pattern-value"
                              ; "nested", `List [ `String ("nested " ^ secret) ]
                              ; "key " ^ secret, `String "benign value"
                              ])
                      ; result =
                          Some
                            (`Assoc
                              [ "password", `String "ordinary-value"
                              ; "summary", `String ("result " ^ secret)
                              ])
                      ; ts = Some ("ts " ^ secret)
                      ; oas_block_index = None
                      }
                  ]
              }
          ]
        ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "rich block secret not persisted" false
        (contains_substring raw secret);
      Alcotest.(check bool) "sensitive keyed value not persisted" false
        (contains_substring raw "plain-non-pattern-value");
      Alcotest.(check bool) "sensitive password value not persisted" false
        (contains_substring raw "ordinary-value");
      Alcotest.(check bool) "rich block redaction marker persisted" true
        (contains_substring raw "[REDACTED]");
      let messages = K.load ~base_dir ~keeper_name in
      let assistant =
        List.find
          (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.Assistant)
          messages
      in
      match assistant.K.blocks with
      | Some blocks ->
        let json = Yojson.Safe.to_string (B.blocks_to_yojson blocks) in
        Alcotest.(check bool) "loaded blocks hide secret" false
          (contains_substring json secret);
        Alcotest.(check bool) "loaded blocks hide sensitive keyed value" false
          (contains_substring json "plain-non-pattern-value");
        Alcotest.(check bool) "loaded blocks hide sensitive password value" false
          (contains_substring json "ordinary-value");
        Alcotest.(check bool) "loaded blocks keep redaction marker" true
          (contains_substring json "[REDACTED]")
      | None -> Alcotest.fail "assistant rich blocks missing")

(* Fusion board_post_id/run_id are opaque lookup keys the dashboard uses to
   lazy-fetch the board post; they are never rendered as text. They must
   survive redaction byte-for-byte so the fusion linkage stays resolvable,
   even for an id that happens to embed a value the redactor would otherwise
   rewrite (a projected keeper secret literal, or a structural secret prefix
   like [sk-]). Free-form content in the same turn is still redacted. *)
let test_append_turn_preserves_fusion_lookup_ids () =
  let base_dir = temp_base_path "keeper-chat-store-fusion-ids" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-fusion-ids" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "fusion-id.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      (* Synthetic ids chosen to trigger redaction if the field were not
         skipped: [board_post_id] embeds the projected secret literal, and
         [run_id] matches the [sk-] structural prefix. *)
      let board_post_id = "p-" ^ secret ^ "-board" in
      let run_id = "sk-run-" ^ secret in
      K.append_turn
        ~base_dir
        ~keeper_name
        ~user_content:"render"
        ~user_attachments:[]
        ~assistant_content:("leak " ^ secret)
        ~blocks:[ B.Fusion { board_post_id; run_id } ]
        ();
      let messages = K.load ~base_dir ~keeper_name in
      let assistant =
        List.find
          (fun (m : K.chat_message) -> K.Role.equal m.role K.Role.Assistant)
          messages
      in
      Alcotest.(check bool) "free-form assistant content still redacted" false
        (contains_substring assistant.K.content secret);
      match assistant.K.blocks with
      | Some [ B.Fusion fusion ] ->
        Alcotest.(check string) "board_post_id preserved verbatim"
          board_post_id fusion.board_post_id;
        Alcotest.(check string) "run_id preserved verbatim" run_id fusion.run_id
      | Some _ -> Alcotest.fail "expected exactly one fusion block"
      | None -> Alcotest.fail "assistant fusion block missing")

(* Read-boundary redaction: rows written before this PR (or by any path that
   bypasses the write-boundary redactors) must still have caller-supplied
   blocks and audio scrubbed before they are served by [load] / [to_json_array]. *)
let test_load_redacts_legacy_raw_blocks_and_audio () =
  let base_dir = temp_base_path "keeper-chat-store-legacy-blocks-audio-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-legacy-blocks-audio-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "legacy-blocks-audio.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      let path = chat_path ~base_dir ~keeper_name in
      let audio_json =
        `Assoc
          [ ("token", `String "voice-token-legacy")
          ; ("mime", `String "audio/mpeg")
          ; ("message_text", `String ("caption " ^ secret))
          ; ("audio_url", `String ("https://cdn.example.com/audio?sig=" ^ secret))
          ]
      in
      let blocks_json =
        B.blocks_to_yojson
          [ B.Text { html = "paragraph " ^ secret }
          ; B.Code { cap = None; html = "code " ^ secret; source = None }
          ]
      in
      let row =
        `Assoc
          [ ("role", `String "assistant")
          ; ("content", `String ("content " ^ secret))
          ; ("ts", `Float 1.0)
          ; ("audio", audio_json)
          ; ("blocks", blocks_json)
          ]
      in
      write_file path (Yojson.Safe.to_string row ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      match messages with
      | [ msg ] ->
        Alcotest.(check bool) "legacy content redacted on load" false
          (contains_substring msg.K.content secret);
        (match msg.K.audio with
         | Some audio ->
           Alcotest.(check bool) "legacy audio message_text redacted on load" false
             (contains_substring audio.message_text secret);
           let audio_url_contains_secret =
             match audio.audio_url with
             | Some url -> contains_substring url secret
             | None -> false
           in
           Alcotest.(check bool) "legacy audio audio_url redacted on load" false
             audio_url_contains_secret
         | None -> Alcotest.fail "legacy audio missing");
        Alcotest.(check bool) "legacy blocks redacted on load" false
          (match msg.K.blocks with
           | Some blocks ->
             contains_substring (Yojson.Safe.to_string (B.blocks_to_yojson blocks)) secret
           | None -> true);
        let json = K.to_json_array messages in
        let s = Yojson.Safe.to_string json in
        Alcotest.(check bool) "to_json_array hides legacy secret" false
          (contains_substring s secret);
        Alcotest.(check bool) "redaction marker present in served payload" true
          (contains_substring s "[REDACTED]")
      | messages ->
        Alcotest.failf "expected 1 message, got %d" (List.length messages))

(* Write-boundary redaction: assistant-initiated messages can carry a synthesized
   voice clip; [message_text] and [audio_url] are caller/free-form surfaces and
   must be scrubbed before [encode_line] persists them. *)
let test_append_assistant_message_redacts_audio () =
  let base_dir = temp_base_path "keeper-chat-store-assistant-audio-redact" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      with_env "MASC_SECRET_DIR" "" @@ fun () ->
      let keeper_name = "keeper-chat-assistant-audio-redact" in
      let root = secret_root_default ~base_dir ~keeper_name in
      let secret = "assistant-audio.secret!" in
      write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
      K.append_assistant_message ~base_dir ~keeper_name
        ~content:("spoken " ^ secret)
        ~audio:
          { K.token = "voice-token-redact"
          ; audio_url = Some ("https://cdn.example.com/audio?sig=" ^ secret)
          ; mime = "audio/mpeg"
          ; duration_sec = Some 1.23
          ; message_text = "caption " ^ secret
          ; device_id = Some "device-1"
          ; expired = false
          }
        ();
      let raw = read_file (chat_path ~base_dir ~keeper_name) in
      Alcotest.(check bool) "assistant content secret not persisted" false
        (contains_substring raw secret);
      Alcotest.(check bool) "assistant audio_url secret not persisted" false
        (contains_substring raw ("https://cdn.example.com/audio?sig=" ^ secret));
      Alcotest.(check bool) "assistant audio message_text secret not persisted" false
        (contains_substring raw ("caption " ^ secret));
      Alcotest.(check bool) "redaction marker persisted" true
        (contains_substring raw "[REDACTED]");
      let messages = K.load ~base_dir ~keeper_name in
      match messages with
      | [ msg ] ->
        Alcotest.(check bool) "loaded assistant content redacted" false
          (contains_substring msg.K.content secret);
        (match msg.K.audio with
         | Some audio ->
           Alcotest.(check bool) "loaded audio message_text redacted" false
             (contains_substring audio.message_text secret);
           let audio_url_contains_secret =
             match audio.audio_url with
             | Some url -> contains_substring url secret
             | None -> false
           in
           Alcotest.(check bool) "loaded audio audio_url redacted" false
             audio_url_contains_secret
         | None -> Alcotest.fail "loaded audio missing")
      | messages ->
        Alcotest.failf "expected 1 message, got %d" (List.length messages))

(* RFC-0233 §7: append_turn stamps the supplied turn_ref on every row of the
   completed turn, it round-trips through load, and to_json_array exposes it
   for the history endpoint. *)
let test_turn_ref_persisted_on_turn_rows () =
  let base_dir = temp_base_path "keeper-chat-store-turnref" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-turnref" in
      let tref = Ids.Turn_ref.make ~trace_id:"trace-abc" ~absolute_turn:7 in
      K.append_turn ~base_dir ~keeper_name ~user_content:"do it"
        ~user_attachments:[]
        ~tool_calls:[ { K.call_id = "t1"; call_name = "Read"; args = "{}" } ]
        ~turn_ref:tref ~assistant_content:"done" ();
      let messages = K.load ~base_dir ~keeper_name in
      List.iter
        (fun (m : K.chat_message) ->
          match m.turn_ref with
          | Some tr ->
              Alcotest.(check string)
                (Printf.sprintf "turn_ref on %s row" (K.Role.to_label m.role))
                "trace-abc#7"
                (Ids.Turn_ref.to_string tr)
          | None -> Alcotest.fail "missing turn_ref on a completed-turn row")
        messages;
      let s = Yojson.Safe.to_string (K.to_json_array messages) in
      Alcotest.(check bool) "turn_ref present in to_json_array" true
        (contains_substring s "trace-abc#7"))

let test_to_json_array_appends_trace_block_to_assistant_turn () =
  let base_dir = temp_base_path "keeper-chat-store-turn-trace" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-turn-trace" in
      let tref = Ids.Turn_ref.make ~trace_id:"trace-ui" ~absolute_turn:12 in
      K.append_turn ~base_dir ~keeper_name ~user_content:"status"
        ~user_attachments:[]
        ~tool_calls:[ { K.call_id = "exec-1"; call_name = "keeper_tasks_list"; args = "{}" } ]
        ~turn_ref:tref ~assistant_content:"done" ();
      let messages = K.load ~base_dir ~keeper_name in
      let trace_block_by_turn_ref turn_ref =
        if Ids.Turn_ref.equal turn_ref tref
        then
          Some
            (B.Trace
               {
                 trace =
                   [
                     B.Trace_think
                       {
                         text = "checking tasks";
                         ts = Some "2026-07-01T00:00:00Z";
                         oas_block_index = None;
                       };
                     B.Trace_tool
                         {
                           name = "keeper_tasks_list";
                           tool_call_id = Some "exec-1";
                           status = Some B.Trace_tool_ok;
                           dur = Some "1ms";
                         args = Some (`Assoc []);
                         result = Some (`Assoc [ ("ok", `Bool true) ]);
                         ts = Some "2026-07-01T00:00:01Z";
                         oas_block_index = None;
                       };
                   ];
               })
        else None
      in
      let rows =
        Yojson.Safe.Util.to_list
          (K.to_json_array ~trace_block_by_turn_ref messages)
      in
      let assistant =
        List.find
          (function
            | `Assoc fields -> (
                match List.assoc_opt "role" fields with
                | Some (`String "assistant") -> true
                | _ -> false)
            | _ -> false)
          rows
      in
      match json_blocks assistant with
      | Some blocks ->
        let last = List.nth blocks (List.length blocks - 1) in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "trace block appended" "trace"
          (last |> member "t" |> to_string);
        Alcotest.(check int) "trace keeps thinking and tool" 2
          (last |> member "trace" |> to_list |> List.length)
      | None -> Alcotest.fail "assistant json missing blocks")

let assistant_row rows =
  List.find
    (function
      | `Assoc fields -> (
          match List.assoc_opt "role" fields with
          | Some (`String "assistant") -> true
          | _ -> false)
      | _ -> false)
    rows

let stream_contract_of row =
  let open Yojson.Safe.Util in
  member "stream_contract" row

let test_to_json_array_stream_contract_without_turn_ref () =
  let base_dir = temp_base_path "keeper-chat-store-stream-contract-legacy" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-stream-contract-legacy" in
      K.append_user_message ~base_dir ~keeper_name ~content:"legacy hi" ();
      let rows =
        Yojson.Safe.Util.to_list
          (K.to_json_array (K.load ~base_dir ~keeper_name))
      in
      match rows with
      | [ row ] ->
          let open Yojson.Safe.Util in
          let contract = stream_contract_of row in
          Alcotest.(check string) "source" "keeper_chat_store"
            (contract |> member "source" |> to_string);
          Alcotest.(check string) "status" "history_without_turn_ref"
            (contract |> member "status" |> to_string);
          Alcotest.(check string) "delivery receipt absent" "no_delivery_receipt"
            (contract |> member "delivery_receipt" |> to_string);
          Alcotest.(check bool) "reason says no turn_ref" true
            (contains_substring
               (contract |> member "reason" |> to_string)
               "no persisted turn_ref")
      | other ->
          Alcotest.failf "expected one row, got %d" (List.length other))

let test_to_json_array_stream_contract_trace_join () =
  let base_dir = temp_base_path "keeper-chat-store-stream-contract-trace" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-stream-contract-trace" in
      let tref = Ids.Turn_ref.make ~trace_id:"trace-stream" ~absolute_turn:5 in
      K.append_turn ~base_dir ~keeper_name ~user_content:"inspect"
        ~user_attachments:[] ~turn_ref:tref ~assistant_content:"done" ();
      let trace_block_by_turn_ref turn_ref =
        if Ids.Turn_ref.equal turn_ref tref then
          Some
            (B.Trace
               { trace =
                   [ B.Trace_think
                       { text = "thinking";
                         ts = Some "2026-07-05T00:00:00Z";
                         oas_block_index = None;
                       };
                   ];
               })
        else None
      in
      let rows =
        Yojson.Safe.Util.to_list
          (K.to_json_array ~trace_block_by_turn_ref
             (K.load ~base_dir ~keeper_name))
      in
      let contract = stream_contract_of (assistant_row rows) in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "source" "backend_turn_trace"
        (contract |> member "source" |> to_string);
      Alcotest.(check string) "status" "backend_trace_join"
        (contract |> member "status" |> to_string);
      Alcotest.(check string) "turn_ref" "trace-stream#5"
        (contract |> member "turn_ref" |> to_string);
      Alcotest.(check string) "trace join is not delivery receipt"
        "no_delivery_receipt"
        (contract |> member "delivery_receipt" |> to_string);
      Alcotest.(check int) "trace event count" 1
        (contract |> member "trace_event_count" |> to_int))

let test_to_json_array_stream_contract_trace_unavailable () =
  let base_dir =
    temp_base_path "keeper-chat-store-stream-contract-no-trace"
  in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-stream-contract-no-trace" in
      let tref =
        Ids.Turn_ref.make ~trace_id:"trace-no-events" ~absolute_turn:9
      in
      K.append_turn ~base_dir ~keeper_name ~user_content:"inspect"
        ~user_attachments:[] ~turn_ref:tref ~assistant_content:"done" ();
      let trace_block_by_turn_ref _turn_ref = None in
      let rows =
        Yojson.Safe.Util.to_list
          (K.to_json_array ~trace_block_by_turn_ref
             (K.load ~base_dir ~keeper_name))
      in
      let contract = stream_contract_of (assistant_row rows) in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "source" "keeper_chat_store"
        (contract |> member "source" |> to_string);
      Alcotest.(check string) "status" "history_without_stream_events"
        (contract |> member "status" |> to_string);
      Alcotest.(check string) "turn_ref" "trace-no-events#9"
        (contract |> member "turn_ref" |> to_string);
      Alcotest.(check string) "missing trace is not delivery receipt"
        "no_delivery_receipt"
        (contract |> member "delivery_receipt" |> to_string);
      Alcotest.(check bool) "reason says no retained trace" true
        (contains_substring
           (contract |> member "reason" |> to_string)
           "no retained trajectory/internal-history events"))

let json_string_list json =
  Yojson.Safe.Util.to_list json |> List.map Yojson.Safe.Util.to_string

let test_to_json_array_stream_contract_lifecycle_replay () =
  let base_dir =
    temp_base_path "keeper-chat-store-stream-contract-lifecycle"
  in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-stream-contract-lifecycle" in
      let tref =
        Ids.Turn_ref.make ~trace_id:"trace-lifecycle" ~absolute_turn:6
      in
      let stream_lifecycle =
        [ K.Run_started
        ; K.Text_message_start
        ; K.Text_message_end
        ; K.Run_finished
        ]
      in
      K.append_turn ~base_dir ~keeper_name ~user_content:"inspect"
        ~user_attachments:[]
        ~tool_calls:[ { K.call_id = "toolu_life"; call_name = "Read"; args = "{}" } ]
        ~turn_ref:tref ~stream_lifecycle ~assistant_content:"done" ();
      (match K.load ~base_dir ~keeper_name with
       | [ user; tool; assistant ] ->
           Alcotest.(check bool) "user row carries no stream lifecycle" true
             (Option.is_none user.stream_lifecycle);
           Alcotest.(check bool) "tool row carries no stream lifecycle" true
             (Option.is_none tool.stream_lifecycle);
           Alcotest.(check (option (list string)))
             "stream lifecycle roundtrips on assistant row"
             (Some
                [ "RUN_STARTED"
                ; "TEXT_MESSAGE_START"
                ; "TEXT_MESSAGE_END"
                ; "RUN_FINISHED"
                ])
             (Option.map
                (List.map (fun event ->
                   match event with
                   | K.Run_started -> "RUN_STARTED"
                   | K.Text_message_start -> "TEXT_MESSAGE_START"
                   | K.Text_message_end -> "TEXT_MESSAGE_END"
                   | K.Run_finished -> "RUN_FINISHED"
                   | K.Run_error -> "RUN_ERROR"))
                assistant.stream_lifecycle)
       | messages ->
           Alcotest.failf "expected user/tool/assistant rows, got %d"
             (List.length messages));
      let trace_block_by_turn_ref turn_ref =
        if Ids.Turn_ref.equal turn_ref tref then
          Some
            (B.Trace
               { trace =
                   [ B.Trace_think
                       { text = "retained trace";
                         ts = Some "2026-07-05T00:00:00Z";
                         oas_block_index = None;
                       };
                   ];
               })
        else None
      in
      let rows =
        Yojson.Safe.Util.to_list
          (K.to_json_array ~trace_block_by_turn_ref
             (K.load ~base_dir ~keeper_name))
      in
      let contract = stream_contract_of (assistant_row rows) in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "source" "backend_stream_lifecycle"
        (contract |> member "source" |> to_string);
      Alcotest.(check string) "status" "backend_lifecycle_replay"
        (contract |> member "status" |> to_string);
      Alcotest.(check string) "terminal event" "RUN_FINISHED"
        (contract |> member "event_name" |> to_string);
      Alcotest.(check string) "lifecycle replay is server-side only"
        "server_lifecycle_replay_only"
        (contract |> member "delivery_receipt" |> to_string);
      Alcotest.(check (list string)) "lifecycle events"
        [ "RUN_STARTED"; "TEXT_MESSAGE_START"; "TEXT_MESSAGE_END"; "RUN_FINISHED" ]
        (json_string_list (contract |> member "lifecycle_events")))

let test_malformed_stream_lifecycle_reads_none () =
  let base_dir = temp_base_path "keeper-chat-store-lifecycle-bad" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-store-lifecycle-bad" in
      let path = chat_path ~base_dir ~keeper_name in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      write_file path
        ({|{"role":"assistant","content":"x","ts":1.0,"turn_ref":"trace-life#7","stream_lifecycle":["RUN_STARTED","NOT_A_REAL_EVENT"]}|}
        ^ "\n");
      (match K.load ~base_dir ~keeper_name with
       | [ m ] ->
           Alcotest.(check bool) "malformed lifecycle reads as None" true
             (Option.is_none m.stream_lifecycle);
           Alcotest.(check bool) "turn_ref still parsed" true
             (Option.is_some m.turn_ref)
       | messages ->
           Alcotest.failf "expected 1 message, got %d" (List.length messages));
      Alcotest.(check (float 0.001)) "drop counted as invalid payload"
        1.0
        (drop_value invalid_payload -. before))

(* A malformed persisted turn_ref is surfaced as a read drop and reads as
   [None] — never repaired — while the row itself stays valid. *)
let test_turn_ref_malformed_reads_none () =
  let base_dir = temp_base_path "keeper-chat-store-turnref-bad" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-turnref-bad" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"assistant","content":"x","ts":1.0,"turn_ref":"no-separator"}|}
        ^ "\n");
      match K.load ~base_dir ~keeper_name with
      | [ m ] ->
          Alcotest.(check bool) "malformed turn_ref reads as None" true
            (m.turn_ref = None)
      | messages ->
          Alcotest.failf "expected 1 message, got %d" (List.length messages))

(* RFC-0233 §7: transcript_of_messages joins persisted rows on the exact
   turn_ref, partitions operator/keeper lines, and excludes rows of other
   turns. turn_transcript_to_json reports found=true and surfaces the
   content. *)
let test_transcript_of_messages_joins_turn_ref () =
  let base_dir = temp_base_path "keeper-chat-store-transcript" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-transcript" in
      let tref_a = Ids.Turn_ref.make ~trace_id:"trace-xyz" ~absolute_turn:3 in
      let tref_b = Ids.Turn_ref.make ~trace_id:"trace-xyz" ~absolute_turn:4 in
      K.append_turn ~base_dir ~keeper_name ~user_content:"request A"
        ~user_attachments:[] ~turn_ref:tref_a ~assistant_content:"reply A" ();
      K.append_turn ~base_dir ~keeper_name ~user_content:"request B"
        ~user_attachments:[] ~turn_ref:tref_b ~assistant_content:"reply B" ();
      let messages = K.load ~base_dir ~keeper_name in
      let t = K.transcript_of_messages messages ~turn_ref:tref_a in
      (match t.user with
       | [ m ] ->
           Alcotest.(check string) "operator request content" "request A"
             m.content
       | other ->
           Alcotest.failf "expected 1 user line, got %d" (List.length other));
      (match t.assistant with
       | [ m ] ->
           Alcotest.(check string) "keeper reply content" "reply A" m.content
       | other ->
           Alcotest.failf "expected 1 assistant line, got %d"
             (List.length other));
      (* Turn B's rows must not leak into turn A's transcript. *)
      List.iter
        (fun (m : K.chat_message) ->
          Alcotest.(check bool)
            "no turn-B content in turn-A transcript" false
            (contains_substring m.content "B"))
        (t.user @ t.assistant);
      let json =
        K.turn_transcript_to_json ~keeper:keeper_name ~turn_ref:tref_a t
      in
      let s = Yojson.Safe.to_string json in
      Alcotest.(check bool) "found=true when rows present" true
        (contains_substring s "\"found\":true");
      Alcotest.(check bool) "turn_ref echoed" true
        (contains_substring s "trace-xyz#3"))

(* An unmatched turn_ref yields empty lists and found=false — explicit
   absence, never a fabricated transcript. *)
let test_transcript_absent_returns_empty () =
  let base_dir = temp_base_path "keeper-chat-store-transcript-absent" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-transcript-absent" in
      let tref = Ids.Turn_ref.make ~trace_id:"trace-present" ~absolute_turn:1 in
      K.append_turn ~base_dir ~keeper_name ~user_content:"hi"
        ~user_attachments:[] ~turn_ref:tref ~assistant_content:"hello" ();
      let messages = K.load ~base_dir ~keeper_name in
      let missing =
        Ids.Turn_ref.make ~trace_id:"trace-absent" ~absolute_turn:99
      in
      let t = K.transcript_of_messages messages ~turn_ref:missing in
      Alcotest.(check int) "no user lines" 0 (List.length t.user);
      Alcotest.(check int) "no assistant lines" 0 (List.length t.assistant);
      let json =
        K.turn_transcript_to_json ~keeper:keeper_name ~turn_ref:missing t
      in
      Alcotest.(check bool) "found=false when no rows match" true
        (contains_substring (Yojson.Safe.to_string json) "\"found\":false"))

let () =
  Alcotest.run "keeper_chat_store"
    [
      ( "paging (RFC-0228)",
        [
          Alcotest.test_case "load_page walks backward (small file)" `Quick
            test_load_page_walks_backward_small_file;
          Alcotest.test_case "load_page binary search (large file)" `Quick
            test_load_page_binary_search_large_file;
        ] );
      ( "persistence_read_drops",
        [
          Alcotest.test_case "malformed rows increment drop metrics" `Quick
            test_load_records_malformed_row_drops;
          Alcotest.test_case "tool row without name dropped" `Quick
            test_tool_row_missing_name_dropped;
          Alcotest.test_case "unknown role row dropped (RFC-0232)" `Quick
            test_unknown_role_row_dropped;
        ] );
      ( "audio_expiry (RFC-0235 P3)",
        [
          Alcotest.test_case "missing file marks clip expired" `Quick
            test_audio_clip_marked_expired_when_file_missing;
          Alcotest.test_case "expired flag round-trips" `Quick
            test_audio_clip_expired_persists_roundtrip;
          Alcotest.test_case "audio_url and device_id persist" `Quick
            test_audio_url_and_device_id_persist;
          Alcotest.test_case "invalid audio token treated as expired" `Quick
            test_invalid_audio_token_treated_as_expired;
        ] );
      ( "backend_blocks (RFC-0235 P3)",
        [
          Alcotest.test_case "assistant row gets backend blocks" `Quick
            test_assistant_row_gets_backend_blocks;
          Alcotest.test_case "user and tool rows have no blocks" `Quick
            test_user_and_tool_rows_have_no_blocks;
          Alcotest.test_case "blocks roundtrip and malformed dropped" `Quick
            test_blocks_roundtrip_and_drop_malformed;
          Alcotest.test_case "supplied thinking blocks are redacted" `Quick
            test_append_turn_redacts_supplied_thinking_blocks;
          Alcotest.test_case "supplied rich block strings are redacted" `Quick
            test_append_turn_redacts_all_supplied_block_strings;
          Alcotest.test_case "fusion lookup ids survive redaction" `Quick
            test_append_turn_preserves_fusion_lookup_ids;
          Alcotest.test_case "legacy raw blocks and audio redacted on load" `Quick
            test_load_redacts_legacy_raw_blocks_and_audio;
          Alcotest.test_case "assistant message audio redacted on append" `Quick
            test_append_assistant_message_redacts_audio;
          Alcotest.test_case "assistant history appends trace block" `Quick
            test_to_json_array_appends_trace_block_to_assistant_turn;
          Alcotest.test_case "history stream contract marks no turn_ref" `Quick
            test_to_json_array_stream_contract_without_turn_ref;
          Alcotest.test_case "history stream contract joins turn trace" `Quick
            test_to_json_array_stream_contract_trace_join;
          Alcotest.test_case "history stream contract marks missing trace" `Quick
            test_to_json_array_stream_contract_trace_unavailable;
          Alcotest.test_case "history stream contract replays durable lifecycle" `Quick
            test_to_json_array_stream_contract_lifecycle_replay;
          Alcotest.test_case "malformed stream lifecycle reads as None" `Quick
            test_malformed_stream_lifecycle_reads_none;
        ] );
      ( "row_kind",
        [
          Alcotest.test_case "failure turn kind roundtrip" `Quick
            test_failure_turn_kind_roundtrip;
          Alcotest.test_case "absent kind reads utterance" `Quick
            test_kind_absent_reads_utterance;
          Alcotest.test_case "unknown kind reported, reads utterance" `Quick
            test_unknown_kind_reported_reads_utterance;
        ] );
      ( "speaker_identity",
        [
          Alcotest.test_case "external speaker roundtrip" `Quick
            test_speaker_external_roundtrip;
          Alcotest.test_case "ambient user line roundtrip (RFC-0226)" `Quick
            test_append_user_message_roundtrip;
          Alcotest.test_case "owner speaker roundtrip" `Quick
            test_speaker_owner_roundtrip;
          Alcotest.test_case "unknown authority reported, not guessed" `Quick
            test_unknown_speaker_authority_reported_not_guessed;
        ] );
      ( "tool_call_persistence",
        [
          Alcotest.test_case "append_turn roundtrip" `Quick
            test_append_turn_roundtrip;
          Alcotest.test_case "legacy lines parse" `Quick
            test_legacy_lines_parse_without_new_fields;
          Alcotest.test_case "message id minted unique and stable (R3)" `Quick
            test_message_id_minted_unique_and_stable;
          Alcotest.test_case "legacy row gets deterministic id (R3)" `Quick
            test_legacy_row_gets_deterministic_id;
          Alcotest.test_case "to_json_array exposes id (R3)" `Quick
            test_to_json_array_exposes_id;
          Alcotest.test_case "recent context renders reply and tool evidence" `Quick
            test_recent_direct_context_renders_prior_reply_and_tool_evidence;
          Alcotest.test_case "recent context omits transport failure as reply" `Quick
            test_recent_direct_context_omits_transport_failure_as_self_reply;
          Alcotest.test_case "recent context omits voice audio self echo" `Quick
            test_recent_direct_context_omits_voice_audio_self_echo;
          Alcotest.test_case "recent context is owner-direct only" `Quick
            test_direct_owner_context_excludes_connector_turns;
          Alcotest.test_case "append_turn redacts projected secrets" `Quick
            test_append_turn_redacts_projected_secrets;
          Alcotest.test_case "load redacts legacy raw secret rows" `Quick
            test_load_redacts_legacy_raw_secret_rows;
          Alcotest.test_case "window counts primaries only" `Quick
            test_window_keeps_tool_lines_of_retained_turns;
          Alcotest.test_case "orphan leading tool lines trimmed" `Quick
            test_orphan_leading_tool_lines_trimmed;
          Alcotest.test_case "tail-bounded load matches full-scan window (RFC-0226 P2)"
            `Quick test_tail_bounded_load_matches_full_scan_window;
          Alcotest.test_case "turn_ref stamped on turn rows + json (RFC-0233 §7)"
            `Quick test_turn_ref_persisted_on_turn_rows;
          Alcotest.test_case "malformed turn_ref reads as None (RFC-0233 §7)"
            `Quick test_turn_ref_malformed_reads_none;
          Alcotest.test_case
            "transcript_of_messages joins turn_ref (RFC-0233 §7)" `Quick
            test_transcript_of_messages_joins_turn_ref;
          Alcotest.test_case
            "transcript absent returns empty + found=false (RFC-0233 §7)"
            `Quick test_transcript_absent_returns_empty;
        ] );
    ]
