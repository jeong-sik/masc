open Alcotest
open Masc
module Usage = Runtime_provider_usage_window
module History = Server_provider_usage_history

let decode decoder json = match decoder (Yojson.Safe.from_string json) with
  | Ok report -> report | Error error -> fail (Usage.decode_error_to_string error)

let fixture test = Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "provider-usage-history-" "" in
  let config = Workspace.default_config base in
  let scope = Runtime_quota_window.scope_of_credential ~provider_id:base None in
  let day = floor (Unix.gettimeofday () /. 86400.) *. 86400. in
  Fun.protect ~finally:(fun () ->
    Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> ());
    Fs_compat.remove_tree base) (fun () -> History.install config; test config scope day))

let points config now =
  match History.read config ~now ~window:History.Seven_days with
  | Error detail -> fail detail
  | Ok json ->
      let open Yojson.Safe.Util in
      check int "all persisted records remain readable" 0 (json |> member "unreadable_reports" |> to_int);
      json |> member "points" |> to_list

let kind point = Yojson.Safe.Util.(point |> member "kind" |> to_string)
let observed point = Yojson.Safe.Util.(point |> member "observed_at" |> to_float)

let removed_cap_and_empty_snapshot () = fixture (fun config scope day ->
  let cap = decode Usage.decode_openrouter_key {|{"data":{"limit":20,"limit_remaining":0}}|} in
  let uncapped = decode Usage.decode_openrouter_key {|{"data":{"limit":null,"usage":21.5}}|} in
  Usage.record ~scope ~observed_at:(day -. 1.) cap;
  Usage.record ~scope ~observed_at:(day +. 10.) cap;
  Usage.record ~scope ~observed_at:(day +. 20.) uncapped;
  let rows = points config (day +. 21.) in
  check int "prior day plus current uncapped report" 2 (List.length rows);
  check bool "spent cap is absent from current day" false
    (List.exists (fun row -> observed row >= day && kind row = "provider:credit limit") rows);
  let current = List.find (fun row -> observed row >= day) rows in
  check string "uncapped USD survives the history boundary" "usd"
    Yojson.Safe.Util.(current |> member "unit" |> to_string);
  check (float 0.) "uncapped amount retained" 21.5
    Yojson.Safe.Util.(current |> member "value" |> to_float);
  Usage.record ~scope ~observed_at:(day +. 30.)
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|});
  let rows = points config (day +. 31.) in
  check int "empty report clears today, not prior days" 1 (List.length rows);
  check (float 0.) "yesterday retains its observed cap" (day -. 1.) (observed (List.hd rows));
  (* A delayed old-format journal append must not revive a window removed by
     the later snapshot. This also covers reading the pre-marker store format. *)
  let journal = Dated_jsonl.create
    ~base_dir:(Filename.concat (Workspace_utils.masc_dir config) "provider_usage_history") () in
  Dated_jsonl.append journal (`List [`Assoc [
    "scope_id", `String (History.scope_id scope); "source", `String (Usage.source_to_string Openrouter_key_read);
    "kind", `String "provider:credit limit"; "limit_id", `Null;
    "observed_at", `Float (day +. 25.); "resets_at", `Null;
    "unit", `String "fraction"; "value", `Float 1.]]);
  check int "late stored old cap stays removed" 1 (List.length (points config (day +. 31.))))

let complete_and_sparse_sources () = fixture (fun config scope day ->
  let antigravity disabled = decode Usage.decode_antigravity_usage (Printf.sprintf
    {|{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"week","window":"weekly","remaining_fraction":0},{"id":"short","window":"5h","remaining_fraction":0,"disabled":%b}]}]}}}|} disabled) in
  Usage.record ~scope ~observed_at:(day +. 10.) (antigravity false);
  Usage.record ~scope ~observed_at:(day +. 20.) (antigravity true);
  let rows = points config (day +. 21.) in
  check (list string) "disabled bucket omitted from daily latest report" ["seven_day"] (List.map kind rows);
  let codex = decode Usage.decode_codex_rate_limits_updated in
  Usage.record ~scope ~observed_at:(day +. 10.)
    (codex {|{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}|});
  Usage.record ~scope ~observed_at:(day +. 20.)
    (codex {|{"rateLimits":{"primary":null,"secondary":{"usedPercent":21,"windowDurationMins":10080}}}|});
  Usage.record ~scope ~observed_at:(day +. 30.) (antigravity true);
  let rows = points config (day +. 31.) |> List.filter (fun row ->
    Yojson.Safe.Util.(row |> member "source" |> to_string)
      = Usage.source_to_string Codex_account_rate_limits_updated) in
  check (list string) "sparse updates retain unstated windows" ["five_hour"; "seven_day"] (List.map kind rows);
  let primary = List.find (fun row -> kind row = "five_hour") rows in
  check (float 0.) "sparse primary retains its original observation" (day +. 10.) (observed primary))

let () = run "provider usage durable snapshots" ["history", [
  test_case "removed cap, empty report, prior day and delayed journal" `Quick removed_cap_and_empty_snapshot;
  test_case "complete bucket omission and sparse event semantics" `Quick complete_and_sparse_sources]]
