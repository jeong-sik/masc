module Safe = Safe_ops_under_test

type encoded = (string * Yojson.Safe.t, string) result

let before json : encoded =
  let repaired = Safe.sanitize_json_utf8 json in
  match Yojson.Safe.to_string (Safe.sanitize_json_utf8 repaired) with
  | body -> Ok (body, repaired)
  | exception Yojson.Json_error message -> Error message

let once json : encoded =
  let repaired = Safe.sanitize_json_utf8 json in
  match Yojson.Safe.to_string repaired with
  | body -> Ok (body, repaired)
  | exception Yojson.Json_error message -> Error message

let checks = ref 0
let require message condition =
  incr checks;
  if not condition then failwith message

let compare name json =
  match before json, once json with
  | Error left, Error right -> require (name ^ ": error") (String.equal left right)
  | Ok (left, original), Ok (right, candidate) ->
    require (name ^ ": encoded bytes") (String.equal left right);
    require (name ^ ": returned value encoding")
      (String.equal (Yojson.Safe.to_string original) (Yojson.Safe.to_string candidate));
    require (name ^ ": idempotent original value")
      (Safe.sanitize_json_utf8 original == original)
  | Error _, Ok _ | Ok _, Error _ -> failwith (name ^ ": error/encoded mismatch")

let document ~rows ~payload =
  `Assoc ["revision", `Int 1; "schedules", `List (List.init rows (fun index ->
    `Assoc ["id", `Int index; "prompt", `String payload; "enabled", `Bool true]))]

let correctness () =
  let scalars = [`Null; `Bool true; `Int 0; `Int min_int; `Intlit "0007";
    `Float nan; `Float infinity; `Float neg_infinity; `Float (-0.0)] in
  List.iteri (fun index json -> compare ("scalar-" ^ string_of_int index) json) scalars;
  for byte = 0 to 255 do
    let text = "prefix" ^ String.make 1 (Char.chr byte) ^ "suffix" in
    compare ("byte-" ^ string_of_int byte)
      (`Assoc [text, `List [`String text; `Assoc ["same", `String text]]])
  done;
  List.iteri (fun index text ->
    compare ("utf8-" ^ string_of_int index)
      (`Assoc [text, `String text; "duplicate", `String text; "duplicate", `String "other"]))
    ["한글 🙂"; "\n\r\t"; "\192\175"; "\237\160\128"; "\240\159\152";
     "quote\" backslash\\"; "\000\127\031"; "\244\144\128\128"];
  compare "nested" (`List [`Assoc []; `List []; `List [`Assoc ["x", `String "\255"]]])

let retained = ref 0
type mode = Twice | Once
let measure mode calls json =
  let f, label = match mode with Twice -> before, "twice" | Once -> once, "once" in
  Gc.full_major ();
  let start = Mtime_clock.now () in
  let cpu = Sys.time () in
  let allocated = Gc.allocated_bytes () in
  for _ = 1 to calls do
    match f (Sys.opaque_identity json) with
    | Error message -> failwith message
    | Ok (body, value) ->
      retained := !retained lxor String.length body;
      ignore (Sys.opaque_identity value)
  done;
  let allocated = Gc.allocated_bytes () -. allocated in
  let cpu = Sys.time () -. cpu in
  let wall = Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span start (Mtime_clock.now ()))) /. 1e9 in
  `Assoc ["mode", `String label; "calls", `Int calls;
    "allocated_counter_bytes", `Float allocated;
    "process_cpu_seconds", `Float cpu; "monotonic_wall_seconds", `Float wall]

let () =
  correctness ();
  let cases = ["ascii-256KiB", document ~rows:64 ~payload:(String.make 4096 'a');
    "unicode-256KiB", document ~rows:64 ~payload:(String.concat "" (List.init 512 (fun _ -> "가🙂")));
    "ascii-4MiB", document ~rows:16 ~payload:(String.make 262144 'b')] in
  let windows = List.concat_map (fun (name, json) ->
    compare name json;
    List.init 4 (fun round ->
      let modes = if round mod 2 = 0 then [Twice; Once] else [Once; Twice] in
      `Assoc ["case", `String name; "round", `Int round;
        "encoded_bytes", `Int (String.length (Yojson.Safe.to_string (Safe.sanitize_json_utf8 json)));
        "results", `List (List.map (fun mode -> measure mode 16 json) modes)])) cases in
  print_endline (Yojson.Safe.to_string (`Assoc ["assertions", `Int !checks;
    "benchmark_scope", `String "Owned pure sanitizer/compact encoder pipeline; no Schedule_store mutation, state decoder or filesystem";
    "windows", `List windows; "checksum", `Int !retained]))
