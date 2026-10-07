open Alcotest
module S = Secret_patterns
module R = Masc.Keeper_secret_redaction

let piece_source = function
  | S.Copied {source;_} | S.Masked {source;_} -> source

let check_coverage ~input ~first ~past pieces =
  let cursor = List.fold_left (fun cursor piece ->
    let source = piece_source piece in
    check int "contiguous source ownership" cursor source.first_byte;
    check bool "nonempty source interval" true (source.past_byte > source.first_byte);
    check bool "source interval stays in input" true (source.past_byte <= String.length input);
    (match piece with
     | S.Copied {source;text} ->
         check string "copied bytes are exactly the original bytes"
           (String.sub input source.first_byte (source.past_byte - source.first_byte)) text
     | S.Masked _ -> ());
    source.past_byte) first pieces in
  check int "complete safe-consumed range" past cursor

let masks pieces = List.filter_map (function
  | S.Copied _ -> None
  | S.Masked {source;replacement} -> Some (source.first_byte,source.past_byte,replacement)) pieces

let mask_testable = list (triple int int string)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_secrets secrets f =
  let base = Filename.temp_dir "redaction-source-spans-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let previous_secret_dir = Sys.getenv_opt "MASC_SECRET_DIR" in
    Unix.putenv "MASC_SECRET_DIR" "";
    Fun.protect ~finally:(fun () -> match previous_secret_dir with
      | Some value -> Unix.putenv "MASC_SECRET_DIR" value
      | None -> Unix.unsetenv "MASC_SECRET_DIR") (fun () ->
    let files = List.mapi (fun index secret ->
      let path = Filename.concat base (string_of_int index) in
      Out_channel.with_open_bin path (fun channel -> output_string channel secret);
      path) secrets in
    let redaction = R.snapshot_with_additional_secret_files ~redact_identity_scalars:false
      ~additional_secret_files:files ~base_path:base ~keeper_name:"source-spans" in
    f redaction))

let test_named_prefix_and_unicode () =
  let prefix = "α before api_key=" in
  let named = "'opaque-value'" and between = " after " and token = "ghp_abcDEF123" in
  let input = prefix ^ named ^ between ^ token in
  let pieces = S.redact_text_mapped input in
  let first = String.length prefix in
  let token_start = first + String.length named + String.length between in
  check string "named credential prefix survives the masking pass"
    (prefix ^ "[REDACTED]" ^ between ^ "[REDACTED]") (S.render_pieces pieces);
  check mask_testable "actual matches retain original UTF-8 byte intervals"
    [first,first + String.length named,"[REDACTED]";
     token_start,String.length input,"[REDACTED]"] (masks pieces);
  check_coverage ~input ~first:0 ~past:(String.length input) pieces;
  check string "existing API projects the same policy" (S.render_pieces pieces) (S.redact_text input)

let test_ordered_composition_and_literal_marker () =
  let credential = "Bearer https://user\t:pass@" in
  let input = credential ^ " next" in
  let pieces = S.redact_text_mapped input in
  check string "URL is masked before the enclosing Bearer pass"
    "[REDACTED] next" (S.render_pieces pieces);
  check mask_testable "later match composes onto the original URL and Bearer bytes"
    [0,String.length credential,"[REDACTED]"] (masks pieces);
  check_coverage ~input ~first:0 ~past:(String.length input) pieces;
  let literal = "[REDACTED] ordinary" in
  let pieces = S.redact_text_mapped literal in
  check mask_testable "a literal marker is not a masking receipt" [] (masks pieces);
  check_coverage ~input:literal ~first:0 ~past:(String.length literal) pieces;
  let input = "ghp_abcdefgh" in
  let pieces = S.redact_text_mapped input
    |> S.mask_matches (Re.compile (Re.str "DACT")) in
  check string "a later match inside generated text keeps exact replacement semantics"
    "[RE[REDACTED]ED]" (S.render_pieces pieces);
  check mask_testable "partial replacement matches do not duplicate source ownership"
    [0,String.length input,"[RE[REDACTED]ED]"] (masks pieces);
  check_coverage ~input ~first:0 ~past:(String.length input) pieces

let test_pem_and_ordinary_text () =
  let prefix = "before\n" and suffix = "\nafter" in
  let pem = "-----BEGIN PRIVATE KEY-----\nopaque body\n-----END PRIVATE KEY-----" in
  let input = prefix ^ pem ^ suffix in
  let pieces = S.redact_text_mapped input in
  check string "whole PEM policy remains unchanged"
    (prefix ^ "[REDACTED]" ^ suffix) (S.render_pieces pieces);
  check mask_testable "PEM span includes its markers and body"
    [String.length prefix,String.length prefix + String.length pem,"[REDACTED]"] (masks pieces);
  check_coverage ~input ~first:0 ~past:(String.length input) pieces;
  let input = "task-1234 and normal text" in
  check string "ordinary source bytes survive" input (S.render_pieces (S.redact_text_mapped input));
  check mask_testable "ordinary identifiers do not become masking events" [] (masks (S.redact_text_mapped input))

let test_exact_longest_first_and_structural_composition () =
  let secret = "shared-secret-body" in
  let longest = "before-" ^ secret ^ "-after" in
  with_secrets [secret;longest] (fun redaction ->
    let input = longest ^ " " ^ secret in
    let pieces = R.redact_text_mapped redaction input in
    check string "longest exact value is replaced before its contained value"
      "[REDACTED] [REDACTED]" (S.render_pieces pieces);
    check mask_testable "both original exact spans survive"
      [0,String.length longest,"[REDACTED]";
       String.length longest + 1,String.length input,"[REDACTED]"] (masks pieces);
    check_coverage ~input ~first:0 ~past:(String.length input) pieces;
    let prefix = "authorization: " in
    let input = prefix ^ longest in
    let pieces = R.redact_text_mapped redaction input in
    check string "structural pass retains a named prefix after exact masking"
      (prefix ^ "[REDACTED]") (S.render_pieces pieces);
    check mask_testable "exact then structural masking retains the original value range"
      [String.length prefix,String.length input,"[REDACTED]"] (masks pieces);
    check_coverage ~input ~first:0 ~past:(String.length input) pieces;
    check string "old Keeper API has identical policy" (S.render_pieces pieces) (R.redact_text redaction input))

let test_stream_watermark_across_secret_chunks () =
  let secret = "span-secret-alpha-private" in
  with_secrets [secret] (fun redaction ->
    let state = R.create_stream_state redaction in
    let first = "keep span-secret-" and second = "alpha-private tail\n" in
    let input = first ^ second in
    let held = R.redact_stream_chunk_mapped state first in
    check int "unsafe prefix is not consumed" 0 held.consumed;
    check int "unsafe prefix has no disclosed pieces" 0 (List.length held.pieces);
    let released = R.redact_stream_chunk_mapped state second in
    check int "watermark counts original bytes, not marker bytes" (String.length input) released.consumed;
    check string "joined secret is masked once" "keep [REDACTED] tail\n" (S.render_pieces released.pieces);
    check mask_testable "one span covers bytes from both input chunks"
      [5,5 + String.length secret,"[REDACTED]"] (masks released.pieces);
    check_coverage ~input ~first:0 ~past:released.consumed released.pieces;
    let next = R.redact_stream_chunk_mapped state "next\r" in
    let all_input = input ^ "next\r" in
    check_coverage ~input:all_input ~first:released.consumed ~past:next.consumed next.pieces;
    let finished = R.redact_stream_finish_mapped state in
    check int "finish after a complete record retains watermark" next.consumed finished.consumed;
    check int "no record is emitted twice" 0 (List.length finished.pieces);
    let plain = R.create_stream_state redaction in
    (* Stateful input arrives in source order, before the stream is finished. *)
    let plain_first = R.redact_stream_chunk plain first in
    let plain_second = R.redact_stream_chunk plain second in
    let plain_next = R.redact_stream_chunk plain "next\r" in
    let plain_finished = R.redact_stream_finish plain in
    check string "plain streaming is the same release projection"
      (S.render_pieces (released.pieces @ next.pieces))
      (plain_first ^ plain_second ^ plain_next ^ plain_finished))

let test_bounded_release_consumes_the_entire_crossing_secret () =
  List.iter (fun secret -> with_secrets [secret] (fun redaction ->
    let input = String.make 4_090 'x' ^ secret ^ String.make 5_000 'y' in
    let state = R.create_stream_state redaction in
    let first = R.redact_stream_chunk_mapped state input in
    check int "actual consumed cursor passes the nominal cut through a complete secret"
      (4_090 + String.length secret) first.consumed;
    check mask_testable "crossing exact secret owns its complete source range"
      [4_090,4_090 + String.length secret,"[REDACTED]"] (masks first.pieces);
    check_coverage ~input ~first:0 ~past:first.consumed first.pieces;
    let tail = R.redact_stream_finish_mapped state in
    check_coverage ~input ~first:first.consumed ~past:tail.consumed tail.pieces;
    check int "finish consumes every source byte" (String.length input) tail.consumed;
    check string "bounded masking does not lose ordinary suffixes"
      (String.make 4_090 'x' ^ "[REDACTED]" ^ String.make 5_000 'y')
      (S.render_pieces (first.pieces @ tail.pieces))))
    ["bounded.flush.secret.value"; String.make 9_000 's']

let test_utf8_chunk_and_bounded_release () =
  let input = "가나다\n" in
  let state = R.create_stream_state R.empty in
  let first = R.redact_stream_chunk_mapped state (String.sub input 0 4) in
  check int "a split codepoint remains held" 0 first.consumed;
  let second = R.redact_stream_chunk_mapped state (String.sub input 4 (String.length input - 4)) in
  check_coverage ~input ~first:0 ~past:second.consumed second.pieces;
  check string "UTF-8 bytes rejoin exactly" input (S.render_pieces second.pieces);
  let input = String.concat "" (List.init 10_000 (fun _ -> "가")) in
  let state = R.create_stream_state R.empty in
  let first = R.redact_stream_chunk_mapped state input in
  check bool "long Unicode record is released before finish" true (first.consumed > 0);
  List.iter (fun piece ->
    let source = piece_source piece in
    check int "bounded start is a codepoint boundary" 0 (source.first_byte mod 3);
    check int "bounded end is a codepoint boundary" 0 (source.past_byte mod 3)) first.pieces;
  let tail = R.redact_stream_finish_mapped state in
  check_coverage ~input ~first:0 ~past:first.consumed first.pieces;
  check_coverage ~input ~first:first.consumed ~past:tail.consumed tail.pieces;
  check string "all Unicode survives bounded releases" input (S.render_pieces (first.pieces @ tail.pieces))

let () = run "redaction source spans" ["source authority",[
  test_case "named prefix and Unicode byte offsets" `Quick test_named_prefix_and_unicode;
  test_case "ordered replacements and literal markers" `Quick test_ordered_composition_and_literal_marker;
  test_case "PEM range and ordinary text policy" `Quick test_pem_and_ordinary_text;
  test_case "longest exact match and structural composition" `Quick test_exact_longest_first_and_structural_composition;
  test_case "stream watermark and split secret" `Quick test_stream_watermark_across_secret_chunks;
  test_case "bounded exact matches advance the actual cursor" `Quick test_bounded_release_consumes_the_entire_crossing_secret;
  test_case "UTF-8 chunk ownership and bounded release" `Quick test_utf8_chunk_and_bounded_release]]
