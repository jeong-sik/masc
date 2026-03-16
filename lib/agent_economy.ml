(** Agent_economy — Currency/reward system for MASC agents

    Append-only JSONL ledger with in-memory balance cache.
    Feature flag gated: MASC_ECONOMY_ENABLED.

    @since Phase 1 — Agent Economy
*)

(** {1 Types} *)

type pressure_mode = Normal | Frugal | Hustle

type transaction_kind =
  | Earn_task_done
  | Earn_board_post
  | Earn_upvote
  | Earn_mention_response
  | Spend_llm_call
  | Spend_deliberation
  | Adjustment

type transaction = {
  id: string;
  agent_name: string;
  kind: transaction_kind;
  amount: float;
  balance_after: float;
  reason: string;
  counterparty: string;
  metadata: Yojson.Safe.t;
  timestamp: float;
}

(** {1 Configuration from Environment} *)

let enabled () =
  Env_config_core.get_bool ~default:false "MASC_ECONOMY_ENABLED"

let initial_balance () =
  Env_config_core.get_float ~default:5.0 "MASC_ECONOMY_INITIAL_BALANCE"

let reward_task_done () =
  Env_config_core.get_float ~default:10.0 "MASC_ECONOMY_REWARD_TASK_DONE"

let reward_board_post () =
  Env_config_core.get_float ~default:1.0 "MASC_ECONOMY_REWARD_BOARD_POST"

let reward_upvote () =
  Env_config_core.get_float ~default:0.5 "MASC_ECONOMY_REWARD_UPVOTE"

let reward_mention_response () =
  Env_config_core.get_float ~default:0.5 "MASC_ECONOMY_REWARD_MENTION_RESPONSE"

let frugal_threshold () =
  Env_config_core.get_float ~default:5.0 "MASC_ECONOMY_FRUGAL_THRESHOLD"

let hustle_threshold () =
  Env_config_core.get_float ~default:0.0 "MASC_ECONOMY_HUSTLE_THRESHOLD"

let reputation_multiplier_enabled () =
  Env_config_core.get_bool ~default:true "MASC_ECONOMY_REPUTATION_MULTIPLIER"

(** {1 Transaction Kind Helpers} *)

let transaction_kind_to_string = function
  | Earn_task_done -> "earn_task_done"
  | Earn_board_post -> "earn_board_post"
  | Earn_upvote -> "earn_upvote"
  | Earn_mention_response -> "earn_mention_response"
  | Spend_llm_call -> "spend_llm_call"
  | Spend_deliberation -> "spend_deliberation"
  | Adjustment -> "adjustment"

let transaction_kind_of_string = function
  | "earn_task_done" -> Some Earn_task_done
  | "earn_board_post" -> Some Earn_board_post
  | "earn_upvote" -> Some Earn_upvote
  | "earn_mention_response" -> Some Earn_mention_response
  | "spend_llm_call" -> Some Spend_llm_call
  | "spend_deliberation" -> Some Spend_deliberation
  | "adjustment" -> Some Adjustment
  | _ -> None

let pressure_mode_to_string = function
  | Normal -> "normal"
  | Frugal -> "frugal"
  | Hustle -> "hustle"

(** {1 Serialization} *)

let transaction_to_json (t : transaction) : Yojson.Safe.t =
  `Assoc [
    ("id", `String t.id);
    ("agent_name", `String t.agent_name);
    ("kind", `String (transaction_kind_to_string t.kind));
    ("amount", `Float t.amount);
    ("balance_after", `Float t.balance_after);
    ("reason", `String t.reason);
    ("counterparty", `String t.counterparty);
    ("metadata", t.metadata);
    ("timestamp", `Float t.timestamp);
  ]

let json_string_field ~default key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> s
     | _ -> default)
  | _ -> default

let json_float_field ~default key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Float f) -> f
     | Some (`Int i) -> float_of_int i
     | _ -> default)
  | _ -> default

let transaction_of_json (json : Yojson.Safe.t) : transaction option =
  let id = json_string_field ~default:"" "id" json in
  let agent_name = json_string_field ~default:"" "agent_name" json in
  let kind_str = json_string_field ~default:"" "kind" json in
  if id = "" || agent_name = "" then None
  else
    match transaction_kind_of_string kind_str with
    | None -> None
    | Some kind ->
      Some {
        id;
        agent_name;
        kind;
        amount = json_float_field ~default:0.0 "amount" json;
        balance_after = json_float_field ~default:0.0 "balance_after" json;
        reason = json_string_field ~default:"" "reason" json;
        counterparty = json_string_field ~default:"system" "counterparty" json;
        metadata =
          (match json with
           | `Assoc fields ->
             (match List.assoc_opt "metadata" fields with
              | Some m -> m
              | None -> `Null)
           | _ -> `Null);
        timestamp = json_float_field ~default:0.0 "timestamp" json;
      }

(** {1 ID Generation} *)

let generate_txn_id () =
  let rnd = Mirage_crypto_rng.generate 8 in
  let hex = String.concat ""
    (List.init (String.length rnd) (fun i ->
       Printf.sprintf "%02x" (Char.code (String.get rnd i))))
  in
  Printf.sprintf "txn-%s" hex

(** {1 Ledger Storage} *)

let economy_dir base_path =
  let masc = Filename.concat base_path ".masc" in
  Filename.concat masc "economy"

let ledger_path base_path =
  Filename.concat (economy_dir base_path) "ledger.jsonl"

let ensure_economy_dir base_path =
  let masc = Filename.concat base_path ".masc" in
  let econ = economy_dir base_path in
  if not (Sys.file_exists masc) then
    Unix.mkdir masc 0o755;
  if not (Sys.file_exists econ) then
    Unix.mkdir econ 0o755

let append_transaction base_path (txn : transaction) : (unit, string) result =
  try
    ensure_economy_dir base_path;
    let path = ledger_path base_path in
    let line = Yojson.Safe.to_string (transaction_to_json txn) ^ "\n" in
    let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 path in
    Common.protect
      ~module_name:"agent_economy"
      ~finally_label:"close_ledger"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc line; flush oc);
    Ok ()
  with e ->
    Error (Printf.sprintf "[agent_economy] ledger write failed: %s"
             (Printexc.to_string e))

(** {1 Balance Cache} *)

(* In-memory balance cache: (base_path, agent_name) -> current balance.
   Namespaced by base_path to prevent cross-workspace contamination. *)
let balance_cache : (string * string, float) Hashtbl.t = Hashtbl.create 32

(* Track whether we have loaded from disk for a given base_path *)
let loaded_paths : (string, bool) Hashtbl.t = Hashtbl.create 4

let load_balances_from_ledger base_path =
  if Hashtbl.mem loaded_paths base_path then ()
  else begin
    let path = ledger_path base_path in
    if Sys.file_exists path then begin
      match Safe_ops.read_file_safe path with
      | Error _ -> ()
      | Ok content ->
        String.split_on_char '\n' content
        |> List.iter (fun line ->
          let trimmed = String.trim line in
          if String.length trimmed > 0 then
            try
              let json = Yojson.Safe.from_string trimmed in
              match transaction_of_json json with
              | Some txn ->
                Hashtbl.replace balance_cache (base_path, txn.agent_name) txn.balance_after
              | None -> ()
            with Yojson.Json_error _ -> ())
    end;
    Hashtbl.replace loaded_paths base_path true
  end

let get_balance ~base_path ~agent_name =
  load_balances_from_ledger base_path;
  match Hashtbl.find_opt balance_cache (base_path, agent_name) with
  | Some b -> b
  | None -> initial_balance ()

(** {1 Reputation Integration} *)

let reward_multiplier ~overall_score =
  (* Map 0.0-1.0 score to 0.5x-1.5x multiplier *)
  let clamped = max 0.0 (min 1.0 overall_score) in
  0.5 +. clamped

let base_reward_for_kind = function
  | Earn_task_done -> reward_task_done ()
  | Earn_board_post -> reward_board_post ()
  | Earn_upvote -> reward_upvote ()
  | Earn_mention_response -> reward_mention_response ()
  | Spend_llm_call | Spend_deliberation | Adjustment -> 0.0

(** {1 Core Operations} *)

let earn ~base_path ~agent_name ~kind ~reason ?reputation_score ?(metadata = `Null) () =
  if not (enabled ()) then Ok (get_balance ~base_path ~agent_name)
  else
    let base_amount = base_reward_for_kind kind in
    if base_amount <= 0.0 then
      Error "[agent_economy] earn called with non-earning kind"
    else
      let multiplier =
        if reputation_multiplier_enabled () then
          match reputation_score with
          | Some score -> reward_multiplier ~overall_score:score
          | None -> 1.0
        else 1.0
      in
      let amount = base_amount *. multiplier in
      let current = get_balance ~base_path ~agent_name in
      let balance_after = current +. amount in
      let txn = {
        id = generate_txn_id ();
        agent_name;
        kind;
        amount;
        balance_after;
        reason;
        counterparty = "system";
        metadata;
        timestamp = Unix.gettimeofday ();
      } in
      match append_transaction base_path txn with
      | Error msg -> Error msg
      | Ok () ->
        Hashtbl.replace balance_cache (base_path, agent_name) balance_after;
        Ok balance_after

let spend ~base_path ~agent_name ~amount ~kind ~reason ?(metadata = `Null) () =
  if not (enabled ()) then Ok (get_balance ~base_path ~agent_name)
  else
    let neg_amount = -.(abs_float amount) in
    let current = get_balance ~base_path ~agent_name in
    let balance_after = current +. neg_amount in
    let txn = {
      id = generate_txn_id ();
      agent_name;
      kind;
      amount = neg_amount;
      balance_after;
      reason;
      counterparty = "system";
      metadata;
      timestamp = Unix.gettimeofday ();
    } in
    match append_transaction base_path txn with
    | Error msg -> Error msg
    | Ok () ->
      Hashtbl.replace balance_cache (base_path, agent_name) balance_after;
      Ok balance_after

(** {1 Behavioral Pressure} *)

let reset_cache () =
  Hashtbl.clear balance_cache;
  Hashtbl.clear loaded_paths

let economic_pressure ~base_path ~agent_name =
  if not (enabled ()) then Normal
  else
    let balance = get_balance ~base_path ~agent_name in
    if balance < hustle_threshold () then Hustle
    else if balance < frugal_threshold () then Frugal
    else Normal
