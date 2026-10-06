(** [masc_candle_grant] — operator gifts outside any Goal.

    Appends one [Candle_event.Granted] row to [<base path>/.masc/candle-ledger.jsonl]
    through {!Candle_grant.grant} (cursor-checked, CAS-retried) and prints the
    receipt. The reason names the occasion and is the duplicate key with the
    keeper: granting the same keeper under the same reason twice is refused,
    so a retried grant run cannot pay twice. Grants emit no keeper wake; a
    keeper learns its balance on its own next turn. *)

let usage =
  {|Usage: masc_candle_grant --keeper NAME --amount-milli N --reason TEXT [OPTIONS]

Credit one keeper with an operator gift.

Options:
  --keeper NAME            the keeper credited; parsed with the shared
                           portable-name grammar
  --amount-milli N         positive integer milli-Candle credited
  --reason TEXT            non-blank occasion; the duplicate key with --keeper
  --base DIR               workspace root (default: MASC_BASE_PATH or cwd)
  -h, --help               print this help

Exit codes:
  0  grant appended; receipt printed
  1  invalid argument / refused grant / ledger error
|}

let error msg =
  prerr_endline msg;
  exit 1
;;

let parse_amount_milli raw =
  let trimmed = String.trim raw in
  let decimal =
    String.length trimmed > 0
    && String.for_all (fun c -> c >= '0' && c <= '9') trimmed
  in
  match (if decimal then int_of_string_opt trimmed else None) with
  | Some n when n > 0 -> n
  | _ -> error (Printf.sprintf "invalid --amount-milli: %S (expected a decimal integer > 0)" raw)
;;

let () =
  let keeper = ref None in
  let amount_milli = ref None in
  let reason = ref None in
  let base = ref None in
  let rec parse = function
    | [] -> ()
    | "-h" :: _ | "--help" :: _ ->
      print_string usage;
      exit 0
    | "--keeper" :: value :: rest ->
      keeper := Some value;
      parse rest
    | "--amount-milli" :: value :: rest ->
      amount_milli := Some (parse_amount_milli value);
      parse rest
    | "--reason" :: value :: rest ->
      reason := Some value;
      parse rest
    | "--base" :: value :: rest ->
      base := Some value;
      parse rest
    | [ flag ] when flag = "--keeper" || flag = "--amount-milli" || flag = "--reason" || flag = "--base" ->
      error (Printf.sprintf "%s needs a value\n%s" flag usage)
    | unknown :: _ -> error (Printf.sprintf "unknown argument: %S\n%s" unknown usage)
  in
  parse (List.tl (Array.to_list Sys.argv));
  let keeper_name =
    match !keeper with
    | Some value -> (
      match Keeper_id.Keeper_name.of_string value with
      | Ok name -> name
      | Error detail -> error ("invalid --keeper: " ^ detail))
    | None -> error ("--keeper is required\n" ^ usage)
  in
  let amount_milli =
    match !amount_milli with
    | Some value -> value
    | None -> error ("--amount-milli is required\n" ^ usage)
  in
  let reason =
    match !reason with
    | Some value -> value
    | None -> error ("--reason is required\n" ^ usage)
  in
  let base_path =
    (match !base with
     | Some value ->
       Masc.Workspace.Explicit (Config_dir_resolver.absolute_path value)
     | None ->
       Masc.Workspace.Explicit (Config_dir_resolver.base_path_or_cwd ()))
    |> Masc.Workspace.runtime_base_path
  in
  match
    Candle_grant.grant
      ~now:Unix.gettimeofday
      ~base_path
      ~keeper:keeper_name
      ~amount_milli
      ~reason
  with
  | Ok receipt ->
    Printf.printf
      "granted %d milli-Candle to %s (%s); balance %d\n"
      receipt.Candle_grant.amount_milli
      receipt.Candle_grant.keeper
      receipt.Candle_grant.reason
      receipt.Candle_grant.balance_milli
  | Error grant_error ->
    error ("grant refused: " ^ Candle_grant.error_to_string grant_error)
;;
