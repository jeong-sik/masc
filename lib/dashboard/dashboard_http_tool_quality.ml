(** Dashboard Tool Quality API — aggregate tool call quality metrics.

    Reads [.masc/tool_calls/] JSONL via {!Keeper_tool_call_log.read_recent}
    and produces summary statistics for dashboard consumption.

    @since 2.260.0 *)

let aggregate ?(n = 5000) () : Yojson.Safe.t =
  let records = Keeper_tool_call_log.read_recent ~n () in
  if records = [] then
    `Assoc [("total", `Int 0); ("success_rate", `Float 0.0);
            ("by_tool", `List []); ("by_keeper", `List []);
            ("failure_categories", `List [])]
  else
  let total = ref 0 in
  let success = ref 0 in
  (* hourly trend: hour_key -> (calls, successes) *)
  let hourly_trend : (string, int ref * int ref) Hashtbl.t = Hashtbl.create 48 in
  (* tool -> (calls, successes, total_ms, truncated_count, total_output_chars) *)
  let tool_stats : (string, int ref * int ref * float ref * int ref * int ref) Hashtbl.t =
    Hashtbl.create 64
  in
  (* keeper -> (calls, successes) *)
  let keeper_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 16
  in
  (* error category -> count *)
  let failure_cats : (string, int ref) Hashtbl.t = Hashtbl.create 32 in
  List.iter (fun record ->
    incr total;
    let tool =
      Safe_ops.json_string_opt "tool" record
      |> Option.value ~default:"unknown"
    in
    let keeper =
      Safe_ops.json_string_opt "keeper" record
      |> Option.value ~default:"unknown"
    in
    let ok = match record with
      | `Assoc fields ->
        (match List.assoc_opt "success" fields with
         | Some (`Bool b) -> b | _ -> false)
      | _ -> false
    in
    let dur = match record with
      | `Assoc fields ->
        (match List.assoc_opt "duration_ms" fields with
         | Some (`Float f) -> f
         | Some (`Int i) -> Float.of_int i
         | _ -> 0.0)
      | _ -> 0.0
    in
    let output_chars = match record with
      | `Assoc fields ->
        (match List.assoc_opt "result_bytes" fields with
         | Some (`Int i) -> i
         | _ ->
           (* Fallback: use output string length for old entries *)
           (match List.assoc_opt "output" fields with
            | Some (`String s) -> String.length s
            | _ -> 0))
      | _ -> 0
    in
    let was_truncated = match record with
      | `Assoc fields -> List.assoc_opt "truncated_to" fields <> None
      | _ -> false
    in
    if ok then incr success;
    (* hourly trend bucketing *)
    let hour_key =
      Safe_ops.json_string_opt "ts" record
      |> Option.map (fun ts ->
        if String.length ts >= 13 then String.sub ts 0 13 else ts)
      |> Option.value ~default:"unknown"
    in
    let (hc, hs) =
      match Hashtbl.find_opt hourly_trend hour_key with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0) in
        Hashtbl.replace hourly_trend hour_key v; v
    in
    incr hc; if ok then incr hs;
    (* tool stats *)
    let (tc, ts, td, ttrunc, tochars) =
      match Hashtbl.find_opt tool_stats tool with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0, ref 0.0, ref 0, ref 0) in
        Hashtbl.replace tool_stats tool v; v
    in
    incr tc; if ok then incr ts; td := !td +. dur;
    tochars := !tochars + output_chars;
    if was_truncated then incr ttrunc;
    (* keeper stats *)
    let (kc, ks) =
      match Hashtbl.find_opt keeper_stats keeper with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0) in
        Hashtbl.replace keeper_stats keeper v; v
    in
    incr kc; if ok then incr ks;
    (* failure category *)
    if not ok then begin
      let output =
        Safe_ops.json_string_opt "output" record
        |> Option.value ~default:""
      in
      let cat =
        if String.length output > 0 then
          (* Extract error key from JSON output *)
          (match Yojson.Safe.from_string output with
           | j ->
             Safe_ops.json_string_opt "error" j
             |> Option.value ~default:"unknown_error"
           | exception Yojson.Json_error _ ->
             (* Try after stripping "error: " prefix *)
             let stripped =
               if String.length output >= 7 && String.sub output 0 7 = "error: "
               then String.sub output 7 (String.length output - 7)
               else output
             in
             (match Yojson.Safe.from_string stripped with
              | j ->
                Safe_ops.json_string_opt "error" j
                |> Option.value ~default:"parse_error"
              | exception Yojson.Json_error _ -> "parse_error"))
        else "empty_output"
      in
      let r = match Hashtbl.find_opt failure_cats cat with
        | Some r -> r
        | None -> let r = ref 0 in Hashtbl.replace failure_cats cat r; r
      in
      incr r
    end
  ) records;
  let total_n = !total in
  let success_n = !success in
  let rate =
    if total_n = 0 then 0.0
    else Float.of_int success_n /. Float.of_int total_n *. 100.0
  in
  (* Sort by call count descending *)
  let by_tool =
    Hashtbl.fold (fun name (c, s, d, ttrunc, tochars) acc ->
      let calls = !c in
      let successes = !s in
      let avg_ms = if calls > 0 then !d /. Float.of_int calls else 0.0 in
      let pct = if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      let avg_output = if calls > 0
        then Float.of_int !tochars /. Float.of_int calls
        else 0.0
      in
      (calls, `Assoc [
        ("name", `String name);
        ("calls", `Int calls);
        ("success_pct", `Float pct);
        ("avg_ms", `Float (Float.round (avg_ms *. 10.0) /. 10.0));
        ("output_truncated_count", `Int !ttrunc);
        ("avg_output_chars", `Float (Float.round (avg_output *. 10.0) /. 10.0));
      ]) :: acc
    ) tool_stats []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let by_keeper =
    Hashtbl.fold (fun name (c, s) acc ->
      let calls = !c in
      let successes = !s in
      let pct = if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      (calls, `Assoc [
        ("name", `String name);
        ("calls", `Int calls);
        ("success_pct", `Float pct);
      ]) :: acc
    ) keeper_stats []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let failure_categories =
    Hashtbl.fold (fun cat r acc ->
      (!r, `Assoc [("category", `String cat); ("count", `Int !r)]) :: acc
    ) failure_cats []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let hourly =
    Hashtbl.fold (fun hour (c, s) acc ->
      let calls = !c in
      let successes = !s in
      let pct = if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      (hour, `Assoc [
        ("hour", `String hour);
        ("calls", `Int calls);
        ("success", `Int successes);
        ("success_rate", `Float (Float.round (pct *. 10.0) /. 10.0));
      ]) :: acc
    ) hourly_trend []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map snd
  in
  `Assoc [
    ("total", `Int total_n);
    ("success", `Int success_n);
    ("failure", `Int (total_n - success_n));
    ("success_rate", `Float (Float.round (rate *. 100.0) /. 100.0));
    ("by_tool", `List by_tool);
    ("by_keeper", `List by_keeper);
    ("failure_categories", `List failure_categories);
    ("hourly_trend", `List hourly);
  ]
