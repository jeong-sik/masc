open Alcotest
open Masc
module Usage = Runtime_provider_usage_window
module History = Server_provider_usage_history

let decode decoder json = match decoder (Yojson.Safe.from_string json) with
  | Ok report -> report | Error error -> fail (Usage.decode_error_to_string error)

let usage_journal config =
  Dated_jsonl.open_store
    (Dated_jsonl.Store.at
       (Workspace_utils.dated_store_root config)
       Provider_usage_history)

let fixture test = Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "provider-usage-history-" "" in
  let config = Workspace.default_config base in
  let scope = Runtime_quota_window.scope_of_credential ~provider_id:base None in
  let day = floor (Unix.gettimeofday () /. 86400.) *. 86400. in
  Fun.protect ~finally:(fun () ->
    Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> ());
    Fs_compat.remove_tree base) (fun () -> History.install config; test config scope day))

let history config now =
  match History.read config ~now ~window:History.Seven_days with
  | Error detail -> fail detail
  | Ok json ->
      let open Yojson.Safe.Util in
      check int "all persisted records remain readable" 0 (json |> member "unreadable_reports" |> to_int);
      (match Tui_decode_usage.decode_provider_usage_history json with
       | Ok _ -> () | Error detail -> fail detail);
      json

let points config now = Yojson.Safe.Util.(history config now |> member "points" |> to_list)
let empty_reports config now = Yojson.Safe.Util.(history config now |> member "reported_no_windows" |> to_list)

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
    (List.exists (fun row -> observed row >= day && kind row = "provider:API key credit limit") rows);
  let current = List.find (fun row -> observed row >= day) rows in
  check string "uncapped USD survives the history boundary" "usd"
    Yojson.Safe.Util.(current |> member "unit" |> to_string);
  check (float 0.) "uncapped amount retained" 21.5
    Yojson.Safe.Util.(current |> member "value" |> to_float);
  Usage.record ~scope ~observed_at:(day +. 30.)
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|});
  let rows = points config (day +. 31.) in
  check int "empty report clears today, not prior days" 1 (List.length rows);
  let empty = empty_reports config (day +. 31.) in
  check int "successful empty day remains reported" 1 (List.length empty);
  check (float 0.) "empty snapshot has its actual observation time" (day +. 30.) (observed (List.hd empty));
  check (float 0.) "yesterday retains its observed cap" (day -. 1.) (observed (List.hd rows));
  (* A delayed old-format journal append must not revive a window removed by
     the later snapshot. This also covers reading the pre-marker store format. *)
  let journal = usage_journal config in
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

let empty_day_and_recovery () = fixture (fun config scope day ->
  let empty = decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|} in
  Usage.record ~scope ~observed_at:(day +. 10.) empty;
  check int "empty-only account has no invented utilization" 0 (List.length (points config (day +. 11.)));
  check int "empty-only account retains the successful report" 1 (List.length (empty_reports config (day +. 11.)));
  Usage.record ~scope ~observed_at:(day +. 20.)
    (decode Usage.decode_openrouter_key {|{"data":{"limit":20,"limit_remaining":15}}|});
  check int "numeric recovery replaces empty state" 0 (List.length (empty_reports config (day +. 21.)));
  check int "numeric recovery remains measured" 1 (List.length (points config (day +. 21.)));
  Usage.record ~scope ~observed_at:(day +. 30.) empty;
  Usage.record ~scope ~observed_at:(day +. 40.)
    (decode Usage.decode_codex_rate_limits_updated {|{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}|});
  check int "another source's surviving window prevents an empty-day claim" 0
    (List.length (empty_reports config (day +. 41.)));
  check int "another source's window remains" 1 (List.length (points config (day +. 41.))))

let overlapping_sources () = fixture (fun config scope day ->
  let codex = decode Usage.decode_codex_rate_limits_updated
    {|{"rateLimits":{"limitId":"shared","primary":{"usedPercent":10,"windowDurationMins":300}}}|} in
  let antigravity disabled = decode Usage.decode_antigravity_usage (Printf.sprintf
    {|{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"shared","window":"5h","remaining_fraction":0.2,"disabled":%b}]}]}}}|} disabled) in
  Usage.record ~scope ~observed_at:(day +. 10.) codex;
  Usage.record ~scope ~observed_at:(day +. 20.) (antigravity false);
  let rows = points config (day +. 21.) in
  check int "same logical window has one daily point" 1 (List.length rows);
  check (float 0.) "newest surviving source selected" (day +. 20.) (observed (List.hd rows));
  Usage.record ~scope ~observed_at:(day +. 30.) (antigravity true);
  let rows = points config (day +. 31.) in
  check int "other source survives complete omission of same-kind window" 1 (List.length rows);
  check (float 0.) "surviving source keeps its original timestamp" (day +. 10.) (observed (List.hd rows));
  check int "another surviving source prevents a false empty day" 0
    (List.length (empty_reports config (day +. 31.))))

let legacy_openrouter_label ~old_kind ~current_kind ~report ~unit ~value ~extra () = fixture (fun config scope day ->
  let journal = usage_journal config in
  let legacy ~source ~observed_at = `Assoc ([
    "scope_id", `String (History.scope_id scope); "source", `String source;
    "kind", `String old_kind; "limit_id", `Null;
    "observed_at", `Float observed_at; "resets_at", `Null;
    "unit", `String unit; "value", `Float value] @ extra) in
  Dated_jsonl.append journal (`List [
    legacy ~source:(Usage.source_to_string Openrouter_key_read) ~observed_at:(day -. 1.);
    legacy ~source:(Usage.source_to_string Openrouter_key_read) ~observed_at:(day +. 1.);
    legacy ~source:(Usage.source_to_string Codex_account_rate_limits_updated)
      ~observed_at:(day -. 86401.)]);
  Usage.record ~scope ~observed_at:(day +. 10.)
    (decode Usage.decode_openrouter_key report);
  let rows = points config (day +. 11.) in
  let openrouter = List.filter (fun row ->
    Yojson.Safe.Util.(row |> member "source" |> to_string)
      = Usage.source_to_string Openrouter_key_read) rows in
  check int "one old day and one current day" 2 (List.length openrouter);
  check (list string) "old and new days share the current series identity"
    [current_kind; current_kind]
    (List.map kind openrouter);
  let old = List.find (fun row -> observed row < day) openrouter in
  check string "historical measurement unit is preserved" unit
    Yojson.Safe.Util.(old |> member "unit" |> to_string);
  check (float 0.) "historical measured value retained" value
    Yojson.Safe.Util.(old |> member "value" |> to_float);
  let other = List.find (fun row ->
    Yojson.Safe.Util.(row |> member "source" |> to_string)
      = Usage.source_to_string Codex_account_rate_limits_updated) rows in
  check string "other source's same label is not renamed" old_kind (kind other))

let damaged_journal_keeps_readable_history () = fixture (fun config scope day ->
  let cap = decode Usage.decode_openrouter_key
    {|{"data":{"limit":20,"limit_remaining":5}}|} in
  Usage.record ~scope ~observed_at:(day -. 1.) cap;
  Usage.record ~scope ~observed_at:(day +. 5.) cap;
  let scope_id = History.scope_id scope in
  let point ~limit_id ~observed_at value =
    [ "scope_id", `String scope_id
    ; "source", `String (Usage.source_to_string Codex_account_rate_limits_updated)
    ; "kind", `String "five_hour"
    ; "limit_id", `String limit_id
    ; "observed_at", `Float observed_at
    ; "resets_at", `Null
    ; "unit", `String "percent"
    ; "value", `Int value
    ]
  in
  let journal = usage_journal config in
  let outside = day -. 7. *. 86400. in
  (* A bad item does not discard its valid neighbors. Its timestamp is outside
     the query, but full decoding still reports the missing nullable field. *)
  Dated_jsonl.append journal (`List [
    `Assoc (point ~limit_id:"before" ~observed_at:(day +. 10.) 10);
    `Assoc (List.remove_assoc "limit_id"
      (point ~limit_id:"invalid" ~observed_at:outside 99));
    `Assoc (point ~limit_id:"after" ~observed_at:(day +. 20.) 20);
    `Assoc (point ~limit_id:"too-old" ~observed_at:outside 30);
    `Assoc (point ~limit_id:"future" ~observed_at:(day +. 100.) 40)]);
  let location = Dated_jsonl.Store.at
    (Workspace_utils.dated_store_root config) Provider_usage_history in
  let dated = Dated_jsonl.Store.dated_path location ~ts:day in
  Fs_compat.append_file dated.path "{broken-json\n";
  Dated_jsonl.append journal (`Int 42);
  (* A later real complete report still replaces only its own current day;
     the other source's neighbors and the prior UTC day's cap survive. *)
  Usage.record ~scope ~observed_at:(day +. 40.)
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null,"usage":21.5}}|});
  let json = match History.read config ~now:(day +. 50.) ~window:History.Seven_days with
    | Ok json -> json | Error detail -> fail detail in
  let reading = match Tui_decode_usage.decode_provider_usage_history json with
    | Ok reading -> reading | Error detail -> fail detail in
  check int "item, syntax and non-list failures reach the consumer" 3
    reading.puh_unreadable_reports;
  check int "valid neighbors, prior day and later report survive" 4
    (List.length reading.puh_points);
  check int "corruption is not a successful empty report" 0
    (List.length reading.puh_reported_no_windows);
  check bool "every point retains the opaque scope" true
    (List.for_all (fun (point : Tui_decode_usage.provider_usage_history_point) ->
      point.puhp_scope_id = scope_id) reading.puh_points);
  let by_limit limit_id = List.find
    (fun (point : Tui_decode_usage.provider_usage_history_point) ->
      point.puhp_limit_id = Some limit_id) reading.puh_points in
  List.iter (fun (limit_id, at, expected) ->
    let point = by_limit limit_id in
    check (float 0.) "neighbor observation time survives" at point.puhp_observed_at;
    match point.puhp_unit with
    | Tui_decode_usage.Utilization_percent value ->
        check int "neighbor utilization survives" expected value
    | Utilization_fraction _ | Utilization_usd _ -> fail "neighbor unit changed")
    ["before", day +. 10., 10; "after", day +. 20., 20];
  let prior = List.find
    (fun (point : Tui_decode_usage.provider_usage_history_point) ->
      point.puhp_observed_at < day) reading.puh_points in
  check (float 0.) "append day does not replace observation day" (day -. 1.)
    prior.puhp_observed_at;
  check string "prior day's cap remains" "provider:API key credit limit" prior.puhp_kind;
  let current = List.find
    (fun (point : Tui_decode_usage.provider_usage_history_point) ->
      point.puhp_observed_at = day +. 40.) reading.puh_points in
  match current.puhp_unit with
  | Tui_decode_usage.Utilization_usd { used; limit = None } ->
      check (float 0.) "later uncapped report survives malformed rows" 21.5 used
  | Utilization_usd { limit = Some _; _ } | Utilization_fraction _
  | Utilization_percent _ -> fail "later report lost its uncapped USD amount")

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (mkdir_p (Filename.dirname dir); Unix.mkdir dir 0o755)

let rec copy_tree src dst =
  if Sys.is_directory src then begin
    mkdir_p dst;
    Array.iter (fun name -> copy_tree (Filename.concat src name) (Filename.concat dst name))
      (Sys.readdir src)
  end else
    Out_channel.with_open_bin dst (fun oc ->
      output_string oc (In_channel.with_open_bin src In_channel.input_all))

let journal_dir config =
  Dated_jsonl.Store.dir
    (Dated_jsonl.Store.at (Workspace_utils.dated_store_root config) Provider_usage_history)

(* The history keeps each day file's fold between reads. Reads taken between
   reports, then one more, answer what a single pass over the same journal
   answers in a workspace no read has kept anything for. *)
let kept_reads_answer_what_one_pass_does () = fixture (fun config scope day ->
  let cap = decode Usage.decode_openrouter_key {|{"data":{"limit":20,"limit_remaining":0}}|} in
  let uncapped = decode Usage.decode_openrouter_key {|{"data":{"limit":null,"usage":21.5}}|} in
  let read config = match History.read config ~now:(day +. 100.) ~window:History.Seven_days with
    | Ok json -> Yojson.Safe.to_string json | Error detail -> fail detail in
  Usage.record ~scope ~observed_at:(day -. 1.) cap;
  ignore (read config);
  Usage.record ~scope ~observed_at:(day +. 10.) cap;
  ignore (read config);
  Usage.record ~scope ~observed_at:(day +. 20.) uncapped;
  Usage.record ~scope ~observed_at:(day +. 30.)
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|});
  let kept = read config in
  let fresh_base = Filename.temp_dir "provider-usage-history-fresh-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree fresh_base) (fun () ->
    let fresh = Workspace.default_config fresh_base in
    copy_tree (journal_dir config) (journal_dir fresh);
    check string "a kept read equals one pass over the journal" (read fresh) kept))

(* The kept fold is the widest window's; a narrower window must not read the
   wide window's earlier days, and a wide read after a narrow one must not
   have dropped them. Alternating windows answer what one pass answers for
   each window. *)
let alternating_windows_answer_one_pass_each () = fixture (fun config scope day ->
  let cap = decode Usage.decode_openrouter_key {|{"data":{"limit":20,"limit_remaining":0}}|} in
  let uncapped = decode Usage.decode_openrouter_key {|{"data":{"limit":null,"usage":21.5}}|} in
  let read config window =
    match History.read config ~now:(day +. 100.) ~window with
    | Ok json -> Yojson.Safe.to_string json
    | Error detail -> fail detail in
  (* The wide window's first day falls outside a one-day window. *)
  Usage.record ~scope ~observed_at:(day -. 1.) cap;
  ignore (read config History.One_day);
  Usage.record ~scope ~observed_at:(day +. 10.) uncapped;
  ignore (read config History.Fourteen_days);
  ignore (read config History.One_day);
  Usage.record ~scope ~observed_at:(day +. 20.) cap;
  ignore (read config History.Seven_days);
  ignore (read config History.One_day);
  let fresh_base = Filename.temp_dir "provider-usage-history-fresh-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree fresh_base) (fun () ->
    let fresh = Workspace.default_config fresh_base in
    copy_tree (journal_dir config) (journal_dir fresh);
    List.iter
      (fun window ->
         check string
           (Printf.sprintf "an alternating %s read equals one pass"
              (match window with
               | History.One_day -> "one-day" | History.Seven_days -> "seven-day"
               | History.Fourteen_days -> "fourteen-day"))
           (read fresh window) (read config window))
      [ History.One_day; History.Seven_days; History.Fourteen_days ]))

(* Z.AI states what each row limits in its answer; the stored row has to say
   it too, because source and kind alone do not. *)
let stored_rows config =
  Dated_jsonl.read_recent (usage_journal config) 1000
  |> List.concat_map (function `List rows -> rows | _ -> [])

let stored_rows_carry_the_window_role () = fixture (fun config scope day ->
  Usage.record ~scope ~observed_at:(day +. 10.) (decode Usage.decode_zai_quota_limit
    {|{"code":200,"msg":"Operation successful","success":true,"data":{"level":"max","limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":4000,"currentValue":270,"remaining":3730,"percentage":6,"nextResetTime":1790326488997,"usageDetails":[{"modelCode":"search-prime","usage":270}]},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":4,"nextResetTime":1790259391823}]}}|});
  let roles =
    stored_rows config
    |> List.filter_map (fun row ->
         match Yojson.Safe.Util.member "limit_id" row, Yojson.Safe.Util.member "role" row with
         | `String limit_id, `String role -> Some (limit_id, role)
         | _ -> None)
    |> List.sort compare in
  check (list (pair string string)) "each window row states its own role"
    [ "TIME_LIMIT", "counts_other_use"; "TOKENS_LIMIT", "gates_model_calls" ] roles)

let other_scope config name =
  Runtime_quota_window.scope_of_credential
    ~provider_id:(config.Workspace.base_path ^ "/" ^ name) None

(* A restart: the reports are on disk and the table has never seen the
   scope. [store_only] has the installed sink store the report for a scope
   of its own, then stores the same rows again under [scope]'s digest, so
   the rows are the sink's and the table holds nothing for [scope]. *)
let store_only config scope ~observed_at report =
  let target = History.scope_id scope in
  let writer = other_scope config (Printf.sprintf "writer-%s-%.0f" target observed_at) in
  Usage.record ~scope:writer ~observed_at report;
  let written = `String (History.scope_id writer) in
  let rows =
    List.filter_map
      (function
        | `Assoc fields when List.assoc_opt "scope_id" fields = Some written ->
            Some
              (`Assoc
                 (List.map
                    (fun (key, value) ->
                      if String.equal key "scope_id" then key, `String target else key, value)
                    fields))
        | _ -> None)
      (stored_rows config)
  in
  Dated_jsonl.append (usage_journal config) (`List rows)

let restore config ~now scopes =
  match History.restore config ~now ~scopes with
  | Ok () -> ()
  | Error detail -> fail detail

let restored scope =
  match Usage.state ~scope with
  | Usage.Reported (first, rest) ->
      List.map
        (fun (r : Usage.recorded) -> r.Usage.window.Usage.limit_id, r.Usage.observed_at)
        (first :: rest)
  | Usage.Not_reported_since_start | Usage.Reported_no_windows _ -> []

let rest_end scope ~now =
  match Runtime_quota_window.rest ~scope ~now with
  | Some (Runtime_quota_window.Reset_stated at) -> Some at
  | Some (Runtime_quota_window.Observed_until at) -> Some at
  | None -> None

(* [tokens]/[time] are percentages; a reset is seconds since the epoch. *)
let zai ~tokens ~tokens_reset ~time ~time_reset =
  let reset = function
    | None -> ""
    | Some at -> Printf.sprintf {|,"nextResetTime":%d000|} (Float.to_int at)
  in
  decode Usage.decode_zai_quota_limit
    (Printf.sprintf
       {|{"code":200,"msg":"Operation successful","success":true,"data":{"level":"max","limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":%d%s},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":%d%s}]}}|}
       time (reset time_reset) tokens (reset tokens_reset))

let restart_rests_a_scope_only_as_a_live_report_would () = fixture (fun config scope day ->
  let now = day +. 60. in
  let ahead = day +. 7200. in
  (* Spent model-call window, reset ahead: rests until that reset. *)
  store_only config scope ~observed_at:(day +. 10.)
    (zai ~tokens:100 ~tokens_reset:(Some ahead) ~time:6 ~time_reset:(Some ahead));
  (* Only the window that does not gate model calls is spent. *)
  let other_use = other_scope config "other-use" in
  store_only config other_use ~observed_at:(day +. 10.)
    (zai ~tokens:4 ~tokens_reset:(Some ahead) ~time:100 ~time_reset:(Some ahead));
  (* Spent, and its stated reset passed before the restart. *)
  let passed = other_scope config "passed" in
  store_only config passed ~observed_at:(day +. 10.)
    (zai ~tokens:100 ~tokens_reset:(Some (day +. 30.)) ~time:6 ~time_reset:(Some ahead));
  (* Spent without a stated reset. *)
  let open_ended = other_scope config "open-ended" in
  store_only config open_ended ~observed_at:(day +. 10.)
    (zai ~tokens:100 ~tokens_reset:None ~time:6 ~time_reset:(Some ahead));
  (* Antigravity: one of two windows spent. *)
  let partly = other_scope config "partly" in
  store_only config partly ~observed_at:(day +. 10.)
    (decode Usage.decode_antigravity_usage
       {|{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"week","window":"weekly","remaining_fraction":0},{"id":"short","window":"5h","remaining_fraction":0.5}]}]}}}|});
  (* Codex: a spent window is shown and rests nothing. *)
  let codex = other_scope config "codex" in
  store_only config codex ~observed_at:(day +. 10.)
    (decode Usage.decode_codex_rate_limits_updated
       (Printf.sprintf
          {|{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":%d},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}|}
          (Float.to_int ahead)));
  let sunk = ref 0 in
  Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> incr sunk);
  restore config ~now [ scope; other_use; passed; open_ended; partly; codex ];
  check int "restored reports are not stored again" 0 !sunk;
  check (option (float 0.)) "spent until a reset ahead" (Some ahead) (rest_end scope ~now);
  check (list (pair (option string) (float 0.))) "windows keep the time they were observed"
    [ Some "TIME_LIMIT", day +. 10.; Some "TOKENS_LIMIT", day +. 10. ] (restored scope);
  check (option (float 0.)) "a spent window that gates no model call" None (rest_end other_use ~now);
  check (option (float 0.)) "a reset that passed" None (rest_end passed ~now);
  check int "a window past its reset is still shown" 2 (List.length (restored passed));
  check (option (float 0.)) "spent without a stated reset" None (rest_end open_ended ~now);
  check (option (float 0.)) "one of two Antigravity windows spent" None (rest_end partly ~now);
  check (option (float 0.)) "a source that rests nothing live" None (rest_end codex ~now);
  check int "its windows are shown" 2 (List.length (restored codex)))

let restart_reads_each_window_of_a_sparse_source () = fixture (fun config scope day ->
  let codex = decode Usage.decode_codex_rate_limits_updated in
  store_only config scope ~observed_at:(day +. 10.)
    (codex {|{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}|});
  store_only config scope ~observed_at:(day +. 20.)
    (codex {|{"rateLimits":{"primary":null,"secondary":{"usedPercent":21,"windowDurationMins":10080}}}|});
  restore config ~now:(day +. 60.) [ scope ];
  check (list (float 0.)) "the window the later report left out keeps its own reading"
    [ day +. 10.; day +. 20. ]
    (List.sort Float.compare (List.map snd (restored scope))))

let restart_leaves_out_rows_without_a_role () = fixture (fun config scope day ->
  Dated_jsonl.append (usage_journal config) (`List [`Assoc [
    "scope_id", `String (History.scope_id scope);
    "source", `String (Usage.source_to_string Usage.Codex_account_rate_limits_updated);
    "kind", `String "five_hour"; "limit_id", `Null;
    "observed_at", `Float (day +. 10.); "resets_at", `Null;
    "unit", `String "percent"; "value", `Int 100]]);
  restore config ~now:(day +. 60.) [ scope ];
  check int "a row stored before rows carried a role is not put back" 0
    (List.length (restored scope));
  check int "and is still read by the daily history" 1 (List.length (points config (day +. 60.))))

let () = run "provider usage durable snapshots" ["history", [
  test_case "stored rows carry the window role" `Quick stored_rows_carry_the_window_role;
  test_case "a restart rests a scope only as a live report would" `Quick
    restart_rests_a_scope_only_as_a_live_report_would;
  test_case "a restart reads each window of a sparse source" `Quick
    restart_reads_each_window_of_a_sparse_source;
  test_case "a restart leaves out rows without a role" `Quick
    restart_leaves_out_rows_without_a_role;
  test_case "damaged journal retains readable history through the typed decoder" `Quick
    damaged_journal_keeps_readable_history;
  test_case "legacy OpenRouter credit label retains history identity" `Quick
    (legacy_openrouter_label ~old_kind:"provider:credit limit"
      ~current_kind:"provider:API key credit limit"
      ~report:{|{"data":{"limit":20,"limit_remaining":5}}|}
      ~unit:"fraction" ~value:0.5 ~extra:[]);
  test_case "uncapped OpenRouter usage retains history identity" `Quick
    (legacy_openrouter_label ~old_kind:"provider:credit usage (all time)"
      ~current_kind:"provider:API key usage (all time)"
      ~report:{|{"data":{"limit":null,"usage":21.5}}|}
      ~unit:"usd" ~value:12.5 ~extra:["limit", `Null]);
  test_case "overlapping source windows survive another source's empty report" `Quick overlapping_sources;
  test_case "empty-only day, recovery and another reporting source" `Quick empty_day_and_recovery;
  test_case "removed cap, empty report, prior day and delayed journal" `Quick removed_cap_and_empty_snapshot;
  test_case "complete bucket omission and sparse event semantics" `Quick complete_and_sparse_sources;
  test_case "kept reads answer what one pass over the journal does" `Quick
    kept_reads_answer_what_one_pass_does;
  test_case "alternating windows answer one pass each" `Quick
    alternating_windows_answer_one_pass_each]]
