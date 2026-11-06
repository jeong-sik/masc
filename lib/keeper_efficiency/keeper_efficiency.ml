(** See [.mli]. *)

type keeper_month = {
  keeper : string;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}

type fleet = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
}

type month_view = {
  month : string;
  generated_at : float;
  days_covered : int;
  keepers : keeper_month list;
  fleet : fleet;
}

let cache_schema = "masc.keeper-efficiency-cache/v1"
let view_schema = "masc.keeper-efficiency/v1"
let cache_dirname = "keeper-efficiency"

let valid_month month =
  match String.split_on_char '-' month with
  | [ year; mon ] ->
    let digits s = String.for_all (fun c -> c >= '0' && c <= '9') s in
    let two_digits s = String.length s = 2 && digits s in
    let four_digits s = String.length s = 4 && digits s in
    if not (four_digits year && two_digits mon) then false
    else
      let n = int_of_string mon in
      n >= 1 && n <= 12
  | _ -> false
;;

let month_of_unix_time time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
;;

let days_in_month month =
  let year = int_of_string (String.sub month 0 4) in
  let mon = int_of_string (String.sub month 5 2) in
  let leap = (year mod 4 = 0 && year mod 100 <> 0) || year mod 400 = 0 in
  match mon with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if leap then 29 else 28
  | _ -> 0
  (* [valid_month] rejected other months before the caller got here. *)
;;

let day_string month day = Printf.sprintf "%s-%02d" month day

(* ------------------------------------------------------------------ *)
(* Wire classification for tool-call rows.

   [record_kind] mirrors {!Keeper_tool_call_log.record_kind}'s wire strings.
   This module reads the ledger without depending on the whole [masc]
   library, so the three strings live here and a test pins them against
   {!Keeper_tool_call_log.record_kind_of_string}. *)

module Tool_row_kind = struct
  type t =
    | Tool_call
    | Composition_run
    | Lifecycle_event

  let of_string = function
    | "tool_call" -> Some Tool_call
    | "composition_run" -> Some Composition_run
    | "lifecycle_event" -> Some Lifecycle_event
    | _ -> None
end

(* ------------------------------------------------------------------ *)
(* Day accumulation *)

type day_acc = {
  keepers : (string, keeper_month) Hashtbl.t;
  turn_ids : (string * int, unit) Hashtbl.t;
}

let empty_day_acc () = { keepers = Hashtbl.create 16; turn_ids = Hashtbl.create 16 }

let zero_keeper name =
  { keeper = name
  ; turns = 0
  ; input_tokens = 0
  ; output_tokens = 0
  ; cost_usd = 0.0
  ; calls = 0
  ; failed = 0
  ; deferred = 0
  ; tool_ms = 0.0
  }

let update_keeper acc name f =
  let current =
    match Hashtbl.find_opt acc.keepers name with
    | Some row -> row
    | None -> zero_keeper name
  in
  Hashtbl.replace acc.keepers name (f current)
;;

(* ---- cost-ledger rows ---- *)

let non_negative_int n = if n < 0 then 0 else n

let saturating_add_int a b =
  let a = non_negative_int a in
  let b = non_negative_int b in
  if a > max_int - b then max_int else a + b
;;

let non_negative_finite_float v =
  if Float.is_nan v || not (Float.is_finite v) || v < 0.0 then 0.0
  else v
;;

let saturating_add_float a b =
  let sum = non_negative_finite_float a +. non_negative_finite_float b in
  if Float.is_nan sum || sum < 0.0 then 0.0
  else if not (Float.is_finite sum) then Float.max_float
  else sum
;;

let fold_cost_row acc json =
  match Cost_ledger.of_json json with
  | Error _ -> acc  (* malformed rows are skipped, as ledger reads skip them *)
  | Ok row ->
    let agent = row.Cost_ledger.agent in
    let mark_turn id acc =
      let key = (agent, id.Cost_ledger.keeper_turn_id) in
      if Hashtbl.mem acc.turn_ids key then acc
      else begin
        Hashtbl.add acc.turn_ids key ();
        update_keeper acc agent (fun k ->
            { k with turns = saturating_add_int k.turns 1 });
        acc
      end
    in
    let acc =
      match Cost_ledger.inference_key row with
      | Some (Cost_ledger.Turn_inference id) -> mark_turn id acc
      | Some (Cost_ledger.Attempt_inference { turn = id; attempt = _ }) -> mark_turn id acc
      | None -> acc
    in
    match row.Cost_ledger.usage_projection with
    | Cost_ledger.Raw_observation _ -> acc
    | Cost_ledger.Resolved_delta
    | Cost_ledger.Resolved_attempt_delta _ ->
      (match row.Cost_ledger.usage with
       | Cost_ledger.Usage_missing -> acc
       | Cost_ledger.Usage_reported reported ->
         let input_tokens = non_negative_int reported.input_tokens in
         let output_tokens = non_negative_int reported.output_tokens in
         let cost_usd = non_negative_finite_float reported.cost_usd in
         update_keeper acc agent (fun k ->
             { k with
               input_tokens = saturating_add_int k.input_tokens input_tokens
             ; output_tokens = saturating_add_int k.output_tokens output_tokens
             ; cost_usd = saturating_add_float k.cost_usd cost_usd
             });
         acc)
;;

(* ---- tool-call rows ---- *)

let assoc_fields (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list option =
  match json with `Assoc fields -> Some fields | _ -> None
;;

let string_member fields name =
  match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None
;;

let int_member fields name =
  match List.assoc_opt name fields with Some (`Int value) -> Some value | _ -> None
;;

let non_neg_int_member fields name =
  match int_member fields name with
  | Some value when value >= 0 -> Some value
  | _ -> None
;;

let float_member fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let non_neg_finite_float_member fields name =
  match float_member fields name with
  | Some value
    when not (Float.is_nan value)
         && Float.is_finite value
         && value >= 0.0 ->
    Some value
  | _ -> None
;;

let fold_tool_row (acc : day_acc) (json : Yojson.Safe.t) : day_acc =
  match assoc_fields json with
  | None -> acc
  | Some fields ->
    let kind_ok =
      match string_member fields "record_kind" with
      | Some kind ->
        (match Tool_row_kind.of_string kind with
         | Some Tool_row_kind.Tool_call -> true
         | Some (Tool_row_kind.Composition_run | Tool_row_kind.Lifecycle_event) -> false
         | None -> false)
      | None -> false
    in
    if not kind_ok then acc
    else
      let name =
        match (string_member fields "keeper", string_member fields "agent_name") with
        | Some keeper, _ -> Some keeper
        | None, Some agent -> Some agent
        | None, None -> None
      in
      match name with
      | None -> acc
      | Some keeper ->
        let duration =
          match float_member fields "duration_ms" with
          | Some ms -> non_negative_finite_float ms
          | None -> 0.0
        in
        update_keeper acc keeper (fun k ->
            let k =
              { k with
                calls = saturating_add_int k.calls 1
              ; tool_ms = saturating_add_float k.tool_ms duration
              }
            in
            match string_member fields "disposition" with
            | Some disposition ->
              (match Tool_result.unit_disposition_of_string disposition with
               | Ok (Tool_result.Completed ()) -> k
               | Ok (Tool_result.Deferred ()) ->
                 { k with deferred = saturating_add_int k.deferred 1 }
               | Ok (Tool_result.Failed ()) ->
                 { k with failed = saturating_add_int k.failed 1 }
               | Error _ -> k)
            | None -> k);
        acc
;;

(* A day file that shrank below its cached boundary was re-read from zero,
   a previously cached day file that was confirmed removed ([ENOENT]) is
   absent from [returned], or an enumerated day file lacks a cursor while the
   cached section already holds state for that ledger (rotation or partial
   cursor loss). In any of these cases this day's cached accumulator is
   stale and the caller folds the day again from an empty accumulator.
   Storage inspection failures on a missing path propagate as [Error] so an
   unreadable ledger never rebuilds and overwrites cached totals. *)
let check_shrank ~label ~has_cached_state ~passed ~returned =
  let untracked_file_with_cached_state =
    (has_cached_state || passed <> [])
    && List.exists
         (fun (path, _boundary) -> not (List.mem_assoc path passed))
         returned
  in
  let rec loop shrank_any = function
    | [] -> Ok (shrank_any || untracked_file_with_cached_state)
    | (path, prior) :: rest ->
      (match List.assoc_opt path returned with
       | Some boundary -> loop (shrank_any || boundary < prior) rest
       | None ->
         (match Unix.lstat path with
          | stats when stats.Unix.st_kind <> Unix.S_REG ->
            Error (Printf.sprintf "%snot a regular file: %s" label path)
          | _stats -> loop true rest
          | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
            loop true rest
          | exception Unix.Unix_error (err, op, arg) ->
            Error
              (Printf.sprintf "%s%s(%s): %s" label op arg
                 (Unix.error_message err))))
  in
  loop false passed
;;

(* ------------------------------------------------------------------ *)
(* Per-day cache sections *)

type day_section = {
  day : int;
  mutable costs_cursors : (string * int) list;
  mutable tool_cursors : (string * int) list;
  mutable turn_ids : (string * int) list;
  mutable keepers : keeper_month list;
}

let empty_section day = { day; costs_cursors = []; tool_cursors = []; turn_ids = []; keepers = [] }

let rec all_some acc = function
  | [] -> Some (List.rev acc)
  | Some v :: rest -> all_some (v :: acc) rest
  | None :: _ -> None
;;

let cursor_pair_of_json = function
  | `Assoc fields ->
    (match (string_member fields "path", non_neg_int_member fields "boundary") with
     | Some path, Some boundary when path <> "" -> Some (path, boundary)
     | _ -> None)
  | _ -> None
;;

let cursors_of_json fields name =
  match List.assoc_opt name fields with
  | Some (`List pairs) ->
    (match all_some [] (List.map cursor_pair_of_json pairs) with
     | Some decoded ->
       let seen = Hashtbl.create (List.length decoded) in
       let unique =
         List.for_all
           (fun (path, _boundary) ->
              if Hashtbl.mem seen path then false
              else (
                Hashtbl.add seen path ();
                true))
           decoded
       in
       if unique then Some decoded else None
     | None -> None)
  | _ -> None
;;

let turn_id_of_json = function
  | `Assoc fields ->
    (match (string_member fields "agent", int_member fields "turn") with
     | Some agent, Some turn when agent <> "" -> Some (agent, turn)
     | _ -> None)
  | _ -> None
;;

let turn_ids_of_json fields =
  match List.assoc_opt "turn_ids" fields with
  | Some (`List ids) -> all_some [] (List.map turn_id_of_json ids)
  | _ -> None
;;

let keeper_of_json = function
  | `Assoc fields ->
    (match
       ( string_member fields "keeper"
       , non_neg_int_member fields "turns"
       , non_neg_int_member fields "input_tokens"
       , non_neg_int_member fields "output_tokens"
       , non_neg_finite_float_member fields "cost_usd"
       , non_neg_int_member fields "calls"
       , non_neg_int_member fields "failed"
       , non_neg_int_member fields "deferred"
       , non_neg_finite_float_member fields "tool_ms" )
     with
     | ( Some keeper
       , Some turns
       , Some input_tokens
       , Some output_tokens
       , Some cost_usd
       , Some calls
       , Some failed
       , Some deferred
       , Some tool_ms )
       when keeper <> "" ->
       Some
         { keeper
         ; turns
         ; input_tokens
         ; output_tokens
         ; cost_usd
         ; calls
         ; failed
         ; deferred
         ; tool_ms
         }
     | _ -> None)
  | _ -> None
;;

let has_positive_cursor cursors =
  List.exists (fun (_path, boundary) -> boundary > 0) cursors
;;

let keeper_has_cost_state (k : keeper_month) =
  k.turns > 0
  || k.input_tokens > 0
  || k.output_tokens > 0
  || k.cost_usd > 0.0
  || (k.calls = 0 && k.failed = 0 && k.deferred = 0 && k.tool_ms = 0.0)
;;

let keeper_has_tool_state (k : keeper_month) =
  k.calls > 0 || k.failed > 0 || k.deferred > 0 || k.tool_ms > 0.0
;;

let turn_ids_consistent_with_keepers ~turn_ids ~(keepers : keeper_month list) =
  let seen_keepers = Hashtbl.create (List.length keepers) in
  let keepers_unique =
    List.for_all
      (fun (k : keeper_month) ->
         if Hashtbl.mem seen_keepers k.keeper then false
         else (
           Hashtbl.add seen_keepers k.keeper ();
           true))
      keepers
  in
  if not keepers_unique then false
  else
    let seen_turns = Hashtbl.create (List.length turn_ids) in
    let counts_by_agent = Hashtbl.create (List.length keepers) in
    let turns_valid =
      List.for_all
        (fun ((agent, _turn) as key) ->
           if not (Hashtbl.mem seen_keepers agent) || Hashtbl.mem seen_turns key
           then false
           else (
             Hashtbl.add seen_turns key ();
             let prev =
               Option.value ~default:0 (Hashtbl.find_opt counts_by_agent agent)
             in
             Hashtbl.replace counts_by_agent agent (saturating_add_int prev 1);
             true))
        turn_ids
    in
    turns_valid
    && List.for_all
         (fun (k : keeper_month) ->
            let expected =
              Option.value ~default:0 (Hashtbl.find_opt counts_by_agent k.keeper)
            in
            Int.equal k.turns expected)
         keepers
;;

let section_of_json day json =
  match json with
  | `Assoc fields ->
    let day_ok =
      match int_member fields "day" with
      | Some d -> Int.equal d day
      | None -> true
    in
    if not day_ok then None
    else
      (match
         ( cursors_of_json fields "costs_cursors"
         , cursors_of_json fields "tool_cursors"
         , turn_ids_of_json fields
         , List.assoc_opt "keepers" fields )
       with
       | Some costs_cursors, Some tool_cursors, Some turn_ids, Some (`List rows) ->
         (match all_some [] (List.map keeper_of_json rows) with
          | Some keepers ->
            let has_cost_state =
              turn_ids <> [] || List.exists keeper_has_cost_state keepers
            in
            let has_tool_state = List.exists keeper_has_tool_state keepers in
            if not (turn_ids_consistent_with_keepers ~turn_ids ~keepers)
               || (has_cost_state && not (has_positive_cursor costs_cursors))
               || (has_tool_state && not (has_positive_cursor tool_cursors))
            then None
            else
              Some
                { day
                ; costs_cursors
                ; tool_cursors
                ; turn_ids
                ; keepers
                }
          | None -> None)
       | _ -> None)
  | _ -> None
;;

let cursors_to_json name pairs =
  ( name
  , `List
      (List.map
         (fun (path, boundary) -> `Assoc [ ("path", `String path); ("boundary", `Int boundary) ])
         pairs) )
;;

let section_to_json section =
  `Assoc
    [ ("day", `Int section.day)
    ; cursors_to_json "costs_cursors" section.costs_cursors
    ; cursors_to_json "tool_cursors" section.tool_cursors
    ; ( "turn_ids"
      , `List
          (List.map
             (fun (agent, turn) -> `Assoc [ ("agent", `String agent); ("turn", `Int turn) ])
             section.turn_ids) )
    ; ( "keepers"
      , `List
          (List.map
             (fun k ->
                `Assoc
                  [ ("keeper", `String k.keeper)
                  ; ("turns", `Int k.turns)
                  ; ("input_tokens", `Int k.input_tokens)
                  ; ("output_tokens", `Int k.output_tokens)
                  ; ("cost_usd", `Float k.cost_usd)
                  ; ("calls", `Int k.calls)
                  ; ("failed", `Int k.failed)
                  ; ("deferred", `Int k.deferred)
                  ; ("tool_ms", `Float k.tool_ms)
                  ])
             section.keepers) )
    ]
;;

type month_cache = { sections : day_section list }

let day_entry_of_json = function
  | `Assoc fields ->
    (match (int_member fields "day", List.assoc_opt "section" fields) with
     | Some day, Some section_json when day >= 1 && day <= 31 ->
       section_of_json day section_json
     | _ -> None)
  | _ -> None
;;

let cache_of_json ~month json =
  match json with
  | `Assoc fields ->
    (match
       ( List.assoc_opt "schema" fields
       , List.assoc_opt "month" fields
       , List.assoc_opt "days" fields )
     with
     | Some (`String schema), Some (`String m), Some (`List days)
       when String.equal schema cache_schema && String.equal m month ->
       (match all_some [] (List.map day_entry_of_json days) with
        | Some sections ->
          let seen_days = Hashtbl.create (List.length sections) in
          let unique_days =
            List.for_all
              (fun (s : day_section) ->
                 if Hashtbl.mem seen_days s.day then false
                 else (
                   Hashtbl.add seen_days s.day ();
                   true))
              sections
          in
          if unique_days then Some { sections } else None
        | None -> None)
     | _ -> None)
  | _ -> None
;;

let cache_to_json ~month cache =
  `Assoc
    [ ("schema", `String cache_schema)
    ; ("month", `String month)
    ; ( "days"
      , `List
          (List.map
             (fun section ->
                `Assoc [ ("day", `Int section.day); ("section", section_to_json section) ])
             cache.sections) )
    ]
;;

let cache_path ~masc_root ~month =
  if valid_month month then
    Ok (Filename.concat masc_root (Filename.concat cache_dirname (month ^ ".json")))
  else Error ("invalid month: " ^ month)
;;

(* The cache is a rebuildable projection when missing or malformed, while an
   unreadable cache file surfaces a storage error so the caller does not
   silently discard or overwrite an existing cache on I/O failure. *)
let read_cache_file path =
  match Unix.lstat path with
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok None
  | exception Unix.Unix_error (err, op, arg) ->
    Error
      (Printf.sprintf "efficiency cache: %s(%s): %s" op arg
         (Unix.error_message err))
  | stats when stats.Unix.st_kind <> Unix.S_REG ->
    Error ("efficiency cache: not a regular file: " ^ path)
  | _stats ->
    (try
       let ic = open_in_bin path in
       Fun.protect
         ~finally:(fun () -> close_in_noerr ic)
         (fun () ->
            try Ok (Some (really_input_string ic (in_channel_length ic))) with
            | End_of_file -> Ok None)
     with
     | Sys_error detail -> Error ("efficiency cache: " ^ detail)
     | Unix.Unix_error (err, op, arg) ->
       Error
         (Printf.sprintf "efficiency cache: %s(%s): %s" op arg
            (Unix.error_message err)))
;;

let load_cache ~masc_root ~month =
  match cache_path ~masc_root ~month with
  | Error detail -> Error detail
  | Ok path ->
    (match read_cache_file path with
     | Error detail -> Error detail
     | Ok None -> Ok { sections = [] }
     | Ok (Some content) ->
       (match Yojson.Safe.from_string content with
        | exception _ -> Ok { sections = [] }
        | json ->
          (match cache_of_json ~month json with
           | Some cache -> Ok cache
           | None -> Ok { sections = [] })))
;;

let save_cache ~masc_root ~month cache =
  match cache_path ~masc_root ~month with
  | Error _ -> ()  (* read_month validated the month before folding *)
  | Ok path ->
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       let json = Yojson.Safe.to_string (cache_to_json ~month cache) in
       match Fs_compat.save_file_atomic path json with
       | Ok () | Error _ -> ()
     with
     | Sys_error _ | Unix.Unix_error _ ->
       (* A failed cache write only costs a later re-read of bytes this call
          already folded; the ledgers are the authority. *)
       ())
;;

(* ------------------------------------------------------------------ *)
(* Month fold *)

let fold_day_store ~label ~store ~day ~cursors ~fold_row acc =
  match Dated_jsonl.range_day_file_paths_result store ~since:day ~until:day with
  | Error err -> Error (label ^ Dated_jsonl.read_error_to_string err)
  | Ok paths ->
    let rec loop acc next_cursors = function
      | [] -> Ok (acc, List.rev next_cursors)
      | path :: rest ->
        (match Unix.lstat path with
         | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
           loop acc next_cursors rest
         | exception Unix.Unix_error (err, op, arg) ->
           Error
             (Printf.sprintf "%s%s(%s): %s" label op arg
                (Unix.error_message err))
         | stats when stats.Unix.st_kind <> Unix.S_REG ->
           Error (Printf.sprintf "%snot a regular file: %s" label path)
         | _stats ->
           let from =
             match List.assoc_opt path cursors with Some n -> n | None -> 0
           in
           (match
              Fs_compat.fold_appended_lines ~path ~from ~init:acc
                ~f:(fun acc line ->
                  match Yojson.Safe.from_string line with
                  | json -> fold_row acc json
                  | exception Yojson.Json_error _ -> acc)
            with
            | acc, boundary -> loop acc ((path, boundary) :: next_cursors) rest
            | exception Sys_error detail -> Error (label ^ detail)
            | exception Unix.Unix_error (err, op, arg) ->
              Error
                (Printf.sprintf "%s%s(%s): %s" label op arg
                   (Unix.error_message err))))
    in
    loop acc [] paths
;;

let compute_month ~costs_store ~tool_store ~month ~cache =
  let open Result.Syntax in
  let sections = List.init (days_in_month month) (fun i -> empty_section (i + 1)) in
  let rec loop = function
    | [] -> Ok { sections }
    | (section : day_section) :: rest ->
      let day = day_string month section.day in
      let cached =
        List.find_opt (fun (s : day_section) -> Int.equal s.day section.day) cache.sections
      in
      let costs_cursors =
        Option.map (fun (s : day_section) -> s.costs_cursors) cached |> Option.value ~default:[]
      in
      let tool_cursors =
        Option.map (fun (s : day_section) -> s.tool_cursors) cached |> Option.value ~default:[]
      in
      let has_cached_cost_state =
        match cached with
        | None -> false
        | Some s -> s.turn_ids <> [] || List.exists keeper_has_cost_state s.keepers
      in
      let has_cached_tool_state =
        match cached with
        | None -> false
        | Some s -> List.exists keeper_has_tool_state s.keepers
      in
      let acc =
        let acc = empty_day_acc () in
        List.iter
          (fun (agent, turn) -> Hashtbl.add acc.turn_ids (agent, turn) ())
          (Option.map (fun (s : day_section) -> s.turn_ids) cached
           |> Option.value ~default:[]);
        List.iter
          (fun k -> Hashtbl.replace acc.keepers k.keeper k)
          (Option.map (fun (s : day_section) -> s.keepers) cached
           |> Option.value ~default:[]);
        acc
      in
      let* acc, returned_costs =
        fold_day_store ~label:"costs store: " ~store:costs_store ~day
          ~cursors:costs_cursors ~fold_row:fold_cost_row acc
      in
      let* acc, returned_tools =
        fold_day_store ~label:"tool_calls store: " ~store:tool_store ~day
          ~cursors:tool_cursors ~fold_row:fold_tool_row acc
      in
      let* costs_shrank =
        check_shrank ~label:"costs store: "
          ~has_cached_state:has_cached_cost_state ~passed:costs_cursors
          ~returned:returned_costs
      in
      let* tools_shrank =
        check_shrank ~label:"tool_calls store: "
          ~has_cached_state:has_cached_tool_state ~passed:tool_cursors
          ~returned:returned_tools
      in
      let* acc, returned_costs, returned_tools =
        if costs_shrank || tools_shrank then
          let fresh = empty_day_acc () in
          let* fresh, returned_costs =
            fold_day_store ~label:"costs store: " ~store:costs_store ~day
              ~cursors:[] ~fold_row:fold_cost_row fresh
          in
          let* fresh, returned_tools =
            fold_day_store ~label:"tool_calls store: " ~store:tool_store ~day
              ~cursors:[] ~fold_row:fold_tool_row fresh
          in
          Ok (fresh, returned_costs, returned_tools)
        else Ok (acc, returned_costs, returned_tools)
      in
      section.costs_cursors <- returned_costs;
      section.tool_cursors <- returned_tools;
      section.turn_ids <- Hashtbl.fold (fun key () list -> key :: list) acc.turn_ids [];
      section.keepers <-
        Hashtbl.fold (fun _ k list -> k :: list) acc.keepers []
        |> List.sort (fun a b -> String.compare a.keeper b.keeper);
      loop rest
  in
  loop sections
;;

(* ------------------------------------------------------------------ *)
(* Month view *)

let add_keeper_months (a : keeper_month) (b : keeper_month) : keeper_month =
  { keeper = b.keeper
  ; turns = saturating_add_int a.turns b.turns
  ; input_tokens = saturating_add_int a.input_tokens b.input_tokens
  ; output_tokens = saturating_add_int a.output_tokens b.output_tokens
  ; cost_usd = saturating_add_float a.cost_usd b.cost_usd
  ; calls = saturating_add_int a.calls b.calls
  ; failed = saturating_add_int a.failed b.failed
  ; deferred = saturating_add_int a.deferred b.deferred
  ; tool_ms = saturating_add_float a.tool_ms b.tool_ms
  }

let fleet_of keepers =
  let totals =
    List.fold_left add_keeper_months (zero_keeper "") keepers
  in
  let turns = totals.turns in
  let per_turn total =
    if turns <= 0 then 0.0
    else
      let q = non_negative_finite_float total /. float_of_int turns in
      if Float.is_nan q || q < 0.0 then 0.0
      else if not (Float.is_finite q) then Float.max_float
      else q
  in
  { turns_total = turns
  ; calls_per_turn = per_turn (float_of_int totals.calls)
  ; tool_s_per_turn = per_turn (totals.tool_ms /. 1000.0)
  ; output_tokens_per_turn = per_turn (float_of_int totals.output_tokens)
  ; input_tokens_per_turn = per_turn (float_of_int totals.input_tokens)
  ; cost_usd_per_turn = per_turn totals.cost_usd
  }
;;

module Keeper_map = Map.Make (String)

let month_view_of_cache ~month ~generated_at (cache : month_cache) =
  let days_covered, merged =
    List.fold_left
      (fun (covered, merged) (section : day_section) ->
         if section.keepers = [] && section.turn_ids = [] then covered, merged
         else
           let merged =
             List.fold_left
               (fun acc k ->
                  match Keeper_map.find_opt k.keeper acc with
                  | Some prev -> Keeper_map.add k.keeper (add_keeper_months prev k) acc
                  | None -> Keeper_map.add k.keeper k acc)
               merged
               section.keepers
           in
           covered + 1, merged)
      (0, Keeper_map.empty)
      cache.sections
  in
  let keepers = Keeper_map.bindings merged |> List.map snd in
  { month; generated_at; days_covered; keepers; fleet = fleet_of keepers }
;;

let month_view_to_json (view : month_view) =
  let keeper_json (k : keeper_month) =
    `Assoc
      [ ("keeper", `String k.keeper)
      ; ("turns", `Int k.turns)
      ; ("input_tokens", `Int k.input_tokens)
      ; ("output_tokens", `Int k.output_tokens)
      ; ("cost_usd", `Float k.cost_usd)
      ; ("calls", `Int k.calls)
      ; ("failed", `Int k.failed)
      ; ("deferred", `Int k.deferred)
      ; ("tool_ms", `Float k.tool_ms)
      ]
  in
  `Assoc
    [ ("schema", `String view_schema)
    ; ("month", `String view.month)
    ; ("generated_at", `Float view.generated_at)
    ; ("days_covered", `Int view.days_covered)
    ; ( "fleet"
      , `Assoc
          [ ("turns_total", `Int view.fleet.turns_total)
          ; ("calls_per_turn", `Float view.fleet.calls_per_turn)
          ; ("tool_s_per_turn", `Float view.fleet.tool_s_per_turn)
          ; ("output_tokens_per_turn", `Float view.fleet.output_tokens_per_turn)
          ; ("input_tokens_per_turn", `Float view.fleet.input_tokens_per_turn)
          ; ("cost_usd_per_turn", `Float view.fleet.cost_usd_per_turn)
          ] )
    ; ("keepers", `List (List.map keeper_json view.keepers))
    ]
;;

let compute_mutex = Stdlib.Mutex.create ()

let open_tool_store ~masc_root =
  let location =
    Dated_jsonl.Store.at
      (Dated_jsonl.Store.root_of_masc_dir masc_root)
      Dated_jsonl.Store.Root.Tool_calls
  in
  try Ok (Dated_jsonl.open_store location) with
  | Sys_error detail -> Error ("tool_calls store: " ^ detail)
;;

let read_month ~masc_root ~month =
  if not (valid_month month) then Error ("invalid month: " ^ month)
  else begin
    Stdlib.Mutex.lock compute_mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock compute_mutex)
      (fun () ->
         let open_store label open_ =
           try Ok (open_ ()) with
           | Sys_error detail -> Error (label ^ detail)
           | Unix.Unix_error (err, op, arg) ->
             Error
               (Printf.sprintf "%s%s(%s): %s" label op arg
                  (Unix.error_message err))
         in
         match
           ( open_store "costs store: " (fun () -> Cost_ledger.store_of_masc_root masc_root)
           , open_tool_store ~masc_root )
         with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok costs_store, Ok tool_store ->
           let open Result.Syntax in
           let* cache = load_cache ~masc_root ~month in
           let* computed = compute_month ~costs_store ~tool_store ~month ~cache in
           save_cache ~masc_root ~month computed;
           Ok (month_view_of_cache ~month ~generated_at:(Unix.time ()) computed))
  end
;;
