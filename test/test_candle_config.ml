let valid_text = {|half_life = "off"
[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|}
let enabled = Candle_config.of_toml_string valid_text

(** candle.toml (RFC-goal-candle-ledger 3.9): off, on, or off with a reason. *)

let pp ppf value = Format.pp_print_string ppf (Candle_config.to_string value)
let config = Alcotest.testable pp ( = )

let disabled_reason = function
  | Candle_config.Disabled { reason } -> reason
  | Candle_config.Off | Candle_config.Enabled _ ->
    Alcotest.fail "expected a disabled config"
;;

let contains ~affix text =
  let n = String.length affix
  and h = String.length text in
  let rec scan i = i + n <= h && (String.equal (String.sub text i n) affix || scan (i + 1)) in
  scan 0
;;

let test_explicit_policy () =
  ignore (disabled_reason (Candle_config.of_toml_string ""));
  match enabled with
  | Candle_config.Enabled policy ->
    List.iter2 (fun grade expected -> Alcotest.(check int) (Candle_grade.to_string grade)
      expected (Candle_config.grade_amount_milli policy.payout grade))
      Candle_grade.all [1000;2000;3000;4000;5000]
  | Off | Disabled _ -> Alcotest.fail "complete payout policy was rejected"
;;

let test_optional_shop_prices () =
  List.iter (fun suffix ->
    match Candle_config.of_toml_string (valid_text ^ suffix) with
    | Candle_config.Enabled policy ->
        List.iter (fun item ->
          Alcotest.(check bool) "omitted price is unpriced" true
            (Candle_config.price policy item = Candle_config.Unpriced))
          Keeper_portrait_item.all;
        Alcotest.(check int) "payout remains enabled" 1000
          (Candle_config.grade_amount_milli policy.payout Candle_grade.Trivial)
    | Off | Disabled _ -> Alcotest.fail "omitting optional prices disabled payouts")
    [""; "[shop]\n"; "[shop.prices_milli]\n"];
  List.iter (fun suffix ->
    ignore (disabled_reason (Candle_config.of_toml_string (valid_text ^ suffix))))
    ["[shop]\nprices_milli = 1\n";
     "[shop]\nunknown = 1\n";
     "[shop.prices_milli]\nunknown_item = 1\n";
     "[shop.prices_milli]\ncrown = -1\n";
     "[shop.prices_milli]\ncrown = \"1\"\n"]
;;


let test_explicit_half_life () =
  let lines = String.split_on_char '\n' valid_text in
  let without = List.filter (fun line -> not (String.starts_with ~prefix:"half_life =" line)) lines
    |> String.concat "\n" in
  ignore (disabled_reason (Candle_config.of_toml_string without));
  List.iter (fun raw ->
    ignore (disabled_reason (Candle_config.of_toml_string ("half_life = " ^ raw ^ "\n" ^ without))))
    ["0";"-1";"true";"1.5";"\"OFF\"";"\"1\"";"{}"];
  List.iter (fun hours -> match Candle_config.of_toml_string
      ("half_life = " ^ string_of_int hours ^ "\n" ^ without) with
    | Enabled policy -> Alcotest.(check bool) "explicit integer hours preserve the configured value" true
        (policy.half_life = Candle_decay.Hours hours)
    | Off | Disabled _ -> Alcotest.fail "valid half-life hours rejected") [1;max_int];
  match enabled with
  | Enabled policy -> Alcotest.(check bool) "Off is explicit and is not a default" true
      (policy.half_life = Candle_decay.Off)
  | Off | Disabled _ -> Alcotest.fail "explicit Off rejected"
;;

let test_policy_boundaries () =
  let text ~weight ~amount = Printf.sprintf
    "half_life = \"off\"\n[payout]\nweight_max = %d\ndeduction_rate = 0\ndeduction_floor = 1000\n[payout.grades_milli]\ntrivial = %d\nsmall = 0\nmedium = 0\nlarge = 0\nepic = 0\n" weight amount in
  List.iter (fun weight ->
    (match Candle_config.of_toml_string (text ~weight ~amount:max_int) with
     | Enabled policy -> Alcotest.(check int) "largest representable amount" max_int policy.payout.trivial_milli
     | Off | Disabled _ -> Alcotest.fail "representable grade amount rejected");
    let beyond = Int64.(to_string (add (of_int max_int) 1L)) in
    let oversized = Printf.sprintf
      "half_life = \"off\"\n[payout]\nweight_max = %d\ndeduction_rate = 0\ndeduction_floor = 1000\n[payout.grades_milli]\ntrivial = %s\nsmall = 0\nmedium = 0\nlarge = 0\nepic = 0\n" weight beyond in
    ignore (disabled_reason (Candle_config.of_toml_string oversized)))
    [1; 1000; 1001; max_int];
  ignore (disabled_reason (Candle_config.of_toml_string (text ~weight:0 ~amount:1)));
  ignore (disabled_reason (Candle_config.of_toml_string (text ~weight:1 ~amount:(-1))));
  let lines = String.split_on_char '\n' valid_text in
  List.iter (fun key ->
    let missing = List.filter (fun line -> not (String.starts_with ~prefix:(key ^ " =") line)) lines in
    ignore (disabled_reason (Candle_config.of_toml_string (String.concat "\n" missing)));
    List.iter (fun value ->
      let changed = List.map (fun line -> if String.starts_with ~prefix:(key ^ " =") line
          then key ^ " = " ^ value else line) lines in
      ignore (disabled_reason (Candle_config.of_toml_string (String.concat "\n" changed))))
      ["true"; "1.5"; "\"10\""])
    ["weight_max"; "deduction_rate"; "deduction_floor"; "trivial"; "small"; "medium"; "large"; "epic"];
  List.iter (fun key -> List.iter (fun value ->
    let changed = List.map (fun line -> if String.starts_with ~prefix:(key ^ " =") line
        then key ^ " = " ^ value else line) lines in
    ignore (disabled_reason (Candle_config.of_toml_string (String.concat "\n" changed)))) ["-1"; "1001"])
    ["deduction_rate"; "deduction_floor"]
;;

let test_a_key_this_build_does_not_know_disables () =
  let reason = disabled_reason (Candle_config.of_toml_string "half_life_hours = 72\n") in
  Alcotest.(check bool) "names the key" true (contains ~affix:"half_life_hours" reason);
  let table = disabled_reason (Candle_config.of_toml_string "[prices]\nfoo = 1\n") in
  Alcotest.(check bool) "names the table" true (contains ~affix:"prices" table)
;;

let test_text_that_is_not_toml_disables () =
  let reason = disabled_reason (Candle_config.of_toml_string "this is = = not toml [") in
  Alcotest.(check bool) "says it is not valid TOML" true (contains ~affix:"not valid TOML" reason)
;;

let with_dir f =
  let dir = Filename.temp_file "candle_config_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun entry -> Sys.remove (Filename.concat dir entry)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)
;;

let test_no_file_is_off () =
  with_dir (fun dir ->
    Alcotest.check
      config
      "nothing at the path"
      Candle_config.Off
      (Candle_config.load_file ~path:(Filename.concat dir "candle.toml")))
;;

let test_a_file_is_read_every_time () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc valid_text);
    Alcotest.check config "valid" enabled (Candle_config.load_file ~path);
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc "surprise = true\n");
    ignore (disabled_reason (Candle_config.load_file ~path));
    Sys.remove path;
    Alcotest.check config "removed" Candle_config.Off (Candle_config.load_file ~path))
;;

let test_a_path_that_cannot_be_read_disables () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Unix.mkdir path 0o755;
    Fun.protect
      ~finally:(fun () -> Unix.rmdir path)
      (fun () ->
        let reason = disabled_reason (Candle_config.load_file ~path) in
        Alcotest.(check bool) "says it could not be read" true (contains ~affix:"could not be read" reason)))
;;

(* A stat that fails for a reason other than the file not being there must not
   read as "no file". A symlink that points at itself fails with ELOOP. *)
let test_a_path_that_cannot_be_examined_disables () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Unix.symlink "candle.toml" path;
    let reason = disabled_reason (Candle_config.load_file ~path) in
    Alcotest.(check bool) "says it could not be examined" true
      (contains ~affix:"could not be examined" reason))
;;

(* A link to a file that is gone ends in ENOENT like a missing file does, but the
   link is there: candle.toml was put there on purpose. *)
let test_a_link_to_a_missing_file_disables () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Unix.symlink (Filename.concat dir "not-mounted.toml") path;
    let reason = disabled_reason (Candle_config.load_file ~path) in
    Alcotest.(check bool) "says it is a link to a missing file" true
      (contains ~affix:"link to a file that does not exist" reason))
;;

(* Opening a FIFO waits for a writer that never comes, and the wait would hold up
   whatever asked whether Candle is on. The alarm turns a regression into a
   failure instead of a hang. *)
let test_a_file_that_is_not_a_regular_file_disables_without_being_opened () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Unix.mkfifo path 0o600;
    let previous =
      Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> failwith "opening candle.toml blocked"))
    in
    let (_ : int) = Unix.alarm 10 in
    Fun.protect
      ~finally:(fun () ->
        let (_ : int) = Unix.alarm 0 in
        Sys.set_signal Sys.sigalrm previous)
      (fun () ->
        let reason = disabled_reason (Candle_config.load_file ~path) in
        Alcotest.(check bool) "says it is not a regular file" true
          (contains ~affix:"not a regular file" reason)))
;;

let () =
  Alcotest.run
    "candle_config"
    [ ( "content"
      , [ Alcotest.test_case "optional shop prices preserve payouts" `Quick test_optional_shop_prices
        ; Alcotest.test_case "arithmetic and required-field boundaries" `Quick test_policy_boundaries
        ; Alcotest.test_case "half-life is explicit and strictly typed" `Quick test_explicit_half_life
        ; Alcotest.test_case "explicit policy is required" `Quick test_explicit_policy
        ; Alcotest.test_case "a key this build does not know disables" `Quick
            test_a_key_this_build_does_not_know_disables
        ; Alcotest.test_case "text that is not TOML disables" `Quick
            test_text_that_is_not_toml_disables
        ] )
    ; ( "file"
      , [ Alcotest.test_case "no file is off" `Quick test_no_file_is_off
        ; Alcotest.test_case "the file is read every time" `Quick test_a_file_is_read_every_time
        ; Alcotest.test_case "a path that cannot be read disables" `Quick
            test_a_path_that_cannot_be_read_disables
        ; Alcotest.test_case "a path that cannot be examined disables" `Quick
            test_a_path_that_cannot_be_examined_disables
        ; Alcotest.test_case "a link to a missing file disables" `Quick
            test_a_link_to_a_missing_file_disables
        ; Alcotest.test_case "a file that is not a regular file disables without being opened"
            `Quick test_a_file_that_is_not_a_regular_file_disables_without_being_opened
        ] )
    ]
;;
