(** Tests for [Keeper_wire_capture] (Phase O observability).

    Covers: env-flag parsing, disabled = no filesystem writes, and enabled =
    one redacted dated jsonl with the expected fields. *)

module Wire = Masc.Keeper_wire_capture

let flag = "MASC_KEEPER_WIRE_CAPTURE"
let set v = Unix.putenv flag v

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      i + nl <= hl && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
    in
    loop 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Recursively collect every *.jsonl under [dir]. *)
let rec find_jsonl dir =
  if not (Sys.file_exists dir) then []
  else if Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun e -> find_jsonl (Filename.concat dir e))
  else if Filename.check_suffix dir ".jsonl" then [ dir ]
  else []

(* Built at runtime so no literal secret appears in the source (the pre-commit
   secret scanner rejects literal [ghp_...] tokens). Secret_redactor detects the
   [ghp_] prefix regardless. *)
let fake_github_token = "ghp_" ^ String.make 36 '7'

let enabled_parsing () =
  set "1";
  Alcotest.(check bool) "1 enables" true (Wire.enabled ());
  set "true";
  Alcotest.(check bool) "true enables" true (Wire.enabled ());
  set "YES";
  Alcotest.(check bool) "YES (case-insensitive) enables" true (Wire.enabled ());
  set "on";
  Alcotest.(check bool) "on enables" true (Wire.enabled ());
  set "";
  Alcotest.(check bool) "empty disables" false (Wire.enabled ());
  set "0";
  Alcotest.(check bool) "0 disables" false (Wire.enabled ());
  set "nope";
  Alcotest.(check bool) "unknown value disables" false (Wire.enabled ())

let disabled_is_noop () =
  set "";
  let base = Filename.temp_dir "wirecap_off" "" in
  Wire.capture_request ~base_path:base ~keeper_name:"sangsu" ~turn_id:1
    ~system_prompt:"sys" ~user_message:"u" ~history_messages:[];
  Alcotest.(check (list string))
    "no jsonl written when disabled" [] (find_jsonl base)

let enabled_writes_redacted () =
  set "1";
  let base = Filename.temp_dir "wirecap_on" "" in
  let history =
    [
      Agent_sdk.Types.assistant_msg "좋아, 연구 시작한다";
      Agent_sdk.Types.user_msg "continue";
    ]
  in
  Wire.capture_request ~base_path:base ~keeper_name:"sangsu" ~turn_id:7
    ~system_prompt:("token " ^ fake_github_token ^ " end")
    ~user_message:"hello world" ~history_messages:history;
  let files = find_jsonl base in
  Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
  let content = read_file (List.hd files) in
  Alcotest.(check bool) "raw github token is redacted" false
    (contains ~needle:fake_github_token content);
  Alcotest.(check bool) "redaction marker present" true
    (contains ~needle:"[REDACTED]" content);
  Alcotest.(check bool) "history_message_count recorded" true
    (contains ~needle:"\"history_message_count\":2" content);
  Alcotest.(check bool) "keeper name recorded" true
    (contains ~needle:"sangsu" content);
  Alcotest.(check bool) "turn_id recorded" true
    (contains ~needle:"\"turn_id\":7" content);
  Alcotest.(check bool) "replayed history text recorded" true
    (contains ~needle:"좋아, 연구 시작한다" content)

let () =
  Alcotest.run "keeper_wire_capture"
    [
      ( "enabled",
        [ Alcotest.test_case "env flag parsing" `Quick enabled_parsing ] );
      ( "capture_request",
        [
          Alcotest.test_case "disabled is a no-op" `Quick disabled_is_noop;
          Alcotest.test_case "enabled writes redacted jsonl" `Quick
            enabled_writes_redacted;
        ] );
    ]
