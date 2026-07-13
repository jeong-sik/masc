(* RFC-0232 P5: shared immutable Surface_ref.

   Pinned here:
   1. Codec totality — every variant round-trips through JSON; unknown
      kinds are an Error, never a default.
   2. lane_label goldens — the single derivation that replaced
      writer-invented [source] strings, byte-identical to the legacy
      labels ("dashboard" / "discord" / "agent" / gate channel).
   3. Lane roundtrip — a typed write persists both the structured
      [surface] field and the derived [source] label; legacy label-only
      rows read back as [surface = None] with their label intact;
      an invalid persisted surface payload is reported and dropped
      without losing the row. *)

open Alcotest

module S = Masc.Surface_ref
module Store = Masc.Keeper_chat_store

let surface : S.t testable =
  testable (fun fmt t -> Format.pp_print_string fmt (S.lane_label t)) S.equal

let all_variants =
  [ S.Dashboard { session_id = None }
  ; S.Dashboard { session_id = Some "sess-1" }
  ; S.Discord
      {
        guild_id = Some "g1";
        channel_id = "c1";
        parent_channel_id = Some "p1";
        thread_id = Some "t1";
      }
  ; S.Discord
      { guild_id = None; channel_id = "c2"; parent_channel_id = None; thread_id = None }
  ; S.Slack { team_id = Some "T1"; channel_id = "C9"; thread_ts = None }
  ; S.Webhook { source = "ci"; event_id = "evt-7" }
  ; S.Agent
  ; S.Gate { label = "discord"; address = [ ("workspace_id", "w1") ] }
  ; S.Gate { label = "custom-connector"; address = [] }
  ]

let test_codec_round_trip () =
  List.iter
    (fun v ->
      match S.of_json (S.to_json v) with
      | Ok decoded -> check surface (S.lane_label v) v decoded
      | Error e -> failf "round trip failed for %s: %s" (S.lane_label v) e)
    all_variants

let test_unknown_kind_is_error () =
  match S.of_json (`Assoc [ ("kind", `String "telepathy") ]) with
  | Error _ -> ()
  | Ok _ -> fail "unknown kind decoded"

let test_lane_label_goldens () =
  check string "dashboard" "dashboard"
    (S.lane_label (S.Dashboard { session_id = None }));
  check string "discord" "discord"
    (S.lane_label
       (S.Discord
          { guild_id = None; channel_id = "c"; parent_channel_id = None; thread_id = None }));
  check string "agent" "agent" (S.lane_label S.Agent);
  check string "gate label verbatim" "my-connector"
    (S.lane_label (S.Gate { label = "my-connector"; address = [] }))

(* ── Lane roundtrip ── *)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let with_base prefix f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
  in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f base)

let lane_path base =
  Filename.concat
    (Filename.concat (Filename.concat base ".masc") "keeper_chat")
    "alice.jsonl"

let test_typed_write_round_trips () =
  with_base "surface-ref-write" (fun base ->
      let ref_ =
        S.Discord
          { guild_id = Some "g1"; channel_id = "c1"; parent_channel_id = None; thread_id = None }
      in
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"hello" ~surface:ref_ ();
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ m ] ->
          check (option surface) "typed surface read back" (Some ref_)
            m.surface;
          check (option string) "label derived from the typed surface"
            (Some "discord") m.source
      | other -> failf "expected 1 line, got %d" (List.length other))

let test_legacy_label_row_reads_back () =
  with_base "surface-ref-legacy" (fun base ->
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"seed" ();
      let oc = open_out_gen [ Open_append ] 0o644 (lane_path base) in
      output_string oc
        "{\"role\":\"user\",\"content\":\"old row\",\"ts\":2.0,\"source\":\"discord\"}\n";
      close_out oc;
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ _seed; legacy ] ->
          check (option surface) "no typed surface on pre-P5 row" None
            legacy.surface;
          check (option string) "legacy label kept verbatim"
            (Some "discord") legacy.source
      | other -> failf "expected 2 lines, got %d" (List.length other))

let test_invalid_surface_payload_keeps_row () =
  with_base "surface-ref-invalid" (fun base ->
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"seed" ();
      let oc = open_out_gen [ Open_append ] 0o644 (lane_path base) in
      output_string oc
        "{\"role\":\"user\",\"content\":\"bad surface\",\"ts\":2.0,\"surface\":{\"kind\":\"telepathy\"}}\n";
      close_out oc;
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ _seed; bad ] ->
          check (option surface) "invalid payload reported, decoded as None"
            None bad.surface;
          check string "row content survives" "bad surface" bad.content
      | other -> failf "expected 2 lines, got %d" (List.length other))

let () =
  Random.self_init ();
  run "surface_ref"
    [
      ( "codec",
        [
          test_case "round trip" `Quick test_codec_round_trip;
          test_case "unknown kind is error" `Quick test_unknown_kind_is_error;
        ] );
      ("labels", [ test_case "lane_label goldens" `Quick test_lane_label_goldens ]);
      ( "lane",
        [
          test_case "typed write round trips" `Quick
            test_typed_write_round_trips;
          test_case "legacy label row" `Quick test_legacy_label_row_reads_back;
          test_case "invalid payload keeps row" `Quick
            test_invalid_surface_payload_keeps_row;
        ] );
    ]
