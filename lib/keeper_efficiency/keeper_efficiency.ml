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
        update_keeper acc agent (fun k -> { k with turns = k.turns + 1 });
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
         update_keeper acc agent (fun k ->
             { k with
               input_tokens = k.input_tokens + reported.input_tokens
             ; output_tokens = k.output_tokens + reported.output_tokens
             ; cost_usd = k.cost_usd +. reported.cost_usd
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

let float_member fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
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
        let duration = match float_member fields "duration_ms" with Some ms -> ms | None -> 0.0 in
        update_keeper acc keeper (fun k ->
            let k = { k with calls = k.calls + 1; tool_ms = k.tool_ms +. duration } in
            match string_member fields "disposition" with
            | Some disposition ->
              (match Tool_result.unit_disposition_of_string disposition with
               | Ok (Tool_result.Completed ()) -> k
               | Ok (Tool_result.Deferred ()) -> { k with deferred = k.deferred + 1 }
               | Ok (Tool_result.Failed ()) -> { k with failed = k.failed + 1 }
               | Error _ -> k)
            | None -> k);
        acc
;;

(* A day file that shrank below its cached boundary was re-read from zero,
   so this day's accumulator counted its rows twice. The caller discards
   that day's accumulator and folds it again from an empty one. *)
let shrank ~passed ~returned =
  List.exists
    (fun (path, prior) ->
       match List.assoc_opt path returned with
       | Some boundary -> boundary < prior
       | None -> false)
    passed
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

let cursors_of_json fields name =
  match List.assoc_opt name fields with
  | Some (`List pairs) ->
    List.filter_map
      (function
        | `Assoc [ ("path", `String path); ("boundary", `Int boundary) ] -> Some (path, boundary)
        | _ -> None)
      pairs
  | _ -> []
;;

let turn_ids_of_json fields =
  match List.assoc_opt "turn_ids" fields with
  | Some (`List ids) ->
    List.filter_map
      (function
        | `Assoc [ ("agent", `String agent); ("turn", `Int turn) ] -> Some (agent, turn)
        | _ -> None)
      ids
  | _ -> []
;;

let keeper_of_json = function
  | `Assoc
      [ ("keeper", `String keeper)
      ; ("turns", `Int turns)
      ; ("input_tokens", `Int input_tokens)
      ; ("output_tokens", `Int output_tokens)
      ; ("cost_usd", `Float cost_usd)
      ; ("calls", `Int calls)
      ; ("failed", `Int failed)
      ; ("deferred", `Int deferred)
      ; ("tool_ms", `Float tool_ms)
      ] ->
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
  | _ -> None
;;

let section_of_json day json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | Some (`List rows) ->
       let keepers = List.filter_map keeper_of_json rows in
       Some
         { day
         ; costs_cursors = cursors_of_json fields "costs_cursors"
         ; tool_cursors = cursors_of_json fields "tool_cursors"
         ; turn_ids = turn_ids_of_json fields
         ; keepers
         }
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
       let sections =
         List.filter_map
           (function
             | `Assoc [ ("day", `Int day); ("section", section_json) ] ->
               section_of_json day section_json
             | _ -> None)
           days
       in
       Some { sections }
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

(* The cache is a rebuildable projection, so an unreadable or malformed
   cache is the empty cache and the next fold rebuilds every day it
   disagreees with. A plain blocking read matches how Dated_jsonl itself
   reads day files. *)
let read_cache_file path =
  match Fs_compat.file_exists path with
  | false -> None
  | true ->
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         try Some (really_input_string ic (in_channel_length ic)) with
         | End_of_file -> None)
;;

let load_cache ~masc_root ~month =
  match cache_path ~masc_root ~month with
  | Error _ -> { sections = [] }
  | Ok path ->
    (match read_cache_file path with
     | None -> { sections = [] }
     | Some content ->
       (match Yojson.Safe.from_string content with
        | exception _ -> { sections = [] }
        | json ->
          (match cache_of_json ~month json with
           | Some cache -> cache
           | None -> { sections = [] })))
;;

let save_cache ~masc_root ~month cache =
  match cache_path ~masc_root ~month with
  | Error _ -> ()  (* read_month validated the month before folding *)
  | Ok path ->
    Fs_compat.mkdir_p (Filename.dirname path);
    let json = Yojson.Safe.to_string (cache_to_json ~month cache) in
    (match Fs_compat.save_file_atomic path json with
     | Ok () -> ()
     | Error _ ->
       (* A failed cache write only costs a later re-read of bytes this call
          already folded; the ledgers are the authority. *)
       ())
;;

(* ------------------------------------------------------------------ *)
(* Month fold *)

let fold_day_store ~store ~day ~cursors ~fold_row acc =
  Dated_jsonl.fold_range_appended store ~since:day ~until:day ~cursors ~init:acc
    ~f:fold_row
;;

let compute_month ~costs_store ~tool_store ~month ~cache =
  let sections = List.init (days_in_month month) (fun i -> empty_section (i + 1)) in
  List.iter
    (fun section ->
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
       let acc, returned_costs, returned_tools =
         let acc, returned_costs =
           fold_day_store ~store:costs_store ~day ~cursors:costs_cursors ~fold_row:fold_cost_row acc
         in
         let acc, returned_tools =
           fold_day_store ~store:tool_store ~day ~cursors:tool_cursors ~fold_row:fold_tool_row acc
         in
         if
           shrank ~passed:costs_cursors ~returned:returned_costs
           || shrank ~passed:tool_cursors ~returned:returned_tools
         then
           let fresh = empty_day_acc () in
           let fresh, returned_costs =
             fold_day_store ~store:costs_store ~day ~cursors:[] ~fold_row:fold_cost_row fresh
           in
           let fresh, returned_tools =
             fold_day_store ~store:tool_store ~day ~cursors:[] ~fold_row:fold_tool_row fresh
           in
           (fresh, returned_costs, returned_tools)
         else (acc, returned_costs, returned_tools)
       in
       section.costs_cursors <- returned_costs;
       section.tool_cursors <- returned_tools;
       section.turn_ids <- Hashtbl.fold (fun key () list -> key :: list) acc.turn_ids [];
       section.keepers <-
         Hashtbl.fold (fun _ k list -> k :: list) acc.keepers []
         |> List.sort (fun a b -> String.compare a.keeper b.keeper))
    sections;
  { sections }
;;

(* ------------------------------------------------------------------ *)
(* Month view *)

let fleet_of keepers =
  let turns = List.fold_left (fun sum (k : keeper_month) -> sum + k.turns) 0 keepers in
  let per_turn total = if turns = 0 then 0.0 else total /. float_of_int turns in
  let totals =
    List.fold_left
      (fun acc (k : keeper_month) ->
         { turns = acc.turns + k.turns
         ; input_tokens = acc.input_tokens + k.input_tokens
         ; output_tokens = acc.output_tokens + k.output_tokens
         ; cost_usd = acc.cost_usd +. k.cost_usd
         ; calls = acc.calls + k.calls
         ; failed = acc.failed + k.failed
         ; deferred = acc.deferred + k.deferred
         ; tool_ms = acc.tool_ms +. k.tool_ms
         ; keeper = ""
         })
      (zero_keeper "")
      keepers
  in
  { turns_total = turns
  ; calls_per_turn = per_turn (float_of_int totals.calls)
  ; tool_s_per_turn = per_turn (totals.tool_ms /. 1000.0)
  ; output_tokens_per_turn = per_turn (float_of_int totals.output_tokens)
  ; input_tokens_per_turn = per_turn (float_of_int totals.input_tokens)
  ; cost_usd_per_turn = per_turn totals.cost_usd
  }
;;

let add_keeper_months (a : keeper_month) (b : keeper_month) : keeper_month =
  { keeper = b.keeper
  ; turns = a.turns + b.turns
  ; input_tokens = a.input_tokens + b.input_tokens
  ; output_tokens = a.output_tokens + b.output_tokens
  ; cost_usd = a.cost_usd +. b.cost_usd
  ; calls = a.calls + b.calls
  ; failed = a.failed + b.failed
  ; deferred = a.deferred + b.deferred
  ; tool_ms = a.tool_ms +. b.tool_ms
  }

let month_view_of_cache ~month ~generated_at (cache : month_cache) =
  let merged = Hashtbl.create 16 in
  let days_covered =
    List.fold_left
      (fun covered (section : day_section) ->
         if section.keepers = [] && section.turn_ids = [] then covered
         else begin
           List.iter
             (fun k ->
                match Hashtbl.find_opt merged k.keeper with
                | Some acc -> Hashtbl.replace merged k.keeper (add_keeper_months acc k)
                | None -> Hashtbl.replace merged k.keeper k)
             section.keepers;
           covered + 1
         end)
      0 cache.sections
  in
  let keepers =
    Hashtbl.fold (fun _ k list -> k :: list) merged []
    |> List.sort (fun a b -> String.compare a.keeper b.keeper)
  in
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
         in
         match
           ( open_store "costs store: " (fun () -> Cost_ledger.store_of_masc_root masc_root)
           , open_tool_store ~masc_root )
         with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok costs_store, Ok tool_store ->
           let cache = load_cache ~masc_root ~month in
           let computed = compute_month ~costs_store ~tool_store ~month ~cache in
           save_cache ~masc_root ~month computed;
           Ok (month_view_of_cache ~month ~generated_at:(Unix.time ()) computed))
  end
;;
