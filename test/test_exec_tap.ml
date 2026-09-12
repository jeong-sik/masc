(** Unit tests for Exec_tap (RFC v5 T0 scaffold).

    No actual process exec — only the record API is exercised, so the
    tests run in milliseconds and cannot race on fs state. *)

let substring_contains ~haystack ~needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec find i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else find (i + 1)
    in
    find 0

let must_contain ~tag line needle =
  if not (substring_contains ~haystack:line ~needle) then
    failwith (Printf.sprintf "%s: expected %S in %S" tag needle line)

let must_not_contain ~tag line needle =
  if substring_contains ~haystack:line ~needle then
    failwith (Printf.sprintf "%s: must not contain %S in %S" tag needle line)

let test_off_is_noop () =
  Exec_tap.disable ();
  assert (not (Exec_tap.enabled ()));
  (* This must not raise, nor touch any writer. *)
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv ~argv:[ "ls" ] ();
  assert (not (Exec_tap.enabled ()))

let test_on_emits_one_line () =
  let captured = ref [] in
  Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
  assert (Exec_tap.enabled ());
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv_with_status
    ~argv:[ "git"; "status" ] ~cwd:"/tmp" ();
  assert (List.length !captured = 1);
  Exec_tap.disable ()

let test_json_shape () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Unix_create_process
    ~argv:[ "ls"; "-la" ]
    ~env:[| "PATH=/usr/bin"; "HOME=/root" |]
    ~cwd:"/tmp" ();
  let line = !captured in
  Exec_tap.disable ();
  must_contain ~tag:"trailing newline" line "}\n";
  must_contain ~tag:"kind field" line "\"kind\":\"Unix.create_process\"";
  must_contain ~tag:"argv[1]" line "\"-la\"";
  must_contain ~tag:"env_keys only" line "\"env_keys\":[\"PATH\",\"HOME\"]";
  must_contain ~tag:"cwd" line "\"cwd\":\"/tmp\"";
  (* Env values must not leak into the line. *)
  must_not_contain ~tag:"env value /usr/bin" line "/usr/bin";
  must_not_contain ~tag:"env value /root" line "/root\""

let test_defaults_are_null () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv ~argv:[ "pwd" ] ();
  let line = !captured in
  Exec_tap.disable ();
  must_contain ~tag:"env null" line "\"env_keys\":null";
  must_contain ~tag:"cwd null" line "\"cwd\":null"

let test_writer_exception_is_swallowed () =
  Exec_tap.enable ~writer:(fun _ -> failwith "intentional");
  (* Must not raise — writer errors are the tap's own problem. *)
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv ~argv:[ "x" ] ();
  Exec_tap.disable ()

let test_multiple_calls_each_line () =
  let captured = ref [] in
  Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
  for i = 0 to 4 do
    Exec_tap.record
      ~kind:Exec_tap.Process_eio_run_argv
      ~argv:[ "echo"; string_of_int i ]
      ()
  done;
  assert (List.length !captured = 5);
  (* Every captured line must end with a newline. *)
  List.iter
    (fun line ->
      assert (String.length line > 0);
      assert (line.[String.length line - 1] = '\n'))
    !captured;
  Exec_tap.disable ()

let test_argv_redaction () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:
      [ "curl"
      ; "-H"
      ; "Authorization: Bearer ghp_super_secret_token"
      ; "https://user:password@api.example.com/v1"
      ; "--flag"; "sk-proj-abc123"
      ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_not_contain ~tag:"bearer secret" line "ghp_super_secret_token";
  must_not_contain ~tag:"url password" line "user:password";
  must_not_contain ~tag:"sk secret" line "sk-proj-abc123";
  must_contain ~tag:"redacted bearer" line "Bearer [REDACTED]";
  must_contain ~tag:"redacted url" line "://[REDACTED]@api.example.com/v1";
  must_contain ~tag:"redacted sk" line "[REDACTED]"

(* The three shapes above are the ones redact_arg was taught. A key shaped
   like none of them reached the corpus as written -- an ElevenLabs key in
   [-H "xi-api-key: ..."] does not start with sk- and is not a Bearer. What
   makes it a credential is where it sits, not what it looks like. *)
let test_header_values_are_redacted_by_position () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:
      [ "curl"
      ; "-H"
      ; "xi-api-key: 9f3c1d2e4b5a6789"
      ; "--header"
      ; "X-Goog-Api-Key: AIzaPlainLookingValue"
      ; "-H"
      ; "Content-Type: application/json"
      ; "https://api.example.com/v1/voices"
      ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_not_contain ~tag:"elevenlabs key" line "9f3c1d2e4b5a6789";
  must_not_contain ~tag:"google key" line "AIzaPlainLookingValue";
  must_contain ~tag:"the header is still named" line "xi-api-key: [REDACTED]";
  must_contain ~tag:"and so is the other one" line "X-Goog-Api-Key: [REDACTED]";
  (* A header that carries no credential stays readable: the corpus exists to
     be read, and hiding a content type helps nobody. *)
  must_contain ~tag:"content type survives" line "Content-Type: application/json";
  must_contain ~tag:"the url survives" line "api.example.com/v1/voices"

(* A header argument that is not [name: value] has no name to judge, so it
   falls back to the shape rules rather than being blanked. *)
let test_a_header_argument_without_a_name_falls_back_to_shapes () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:[ "curl"; "-H"; "sk-proj-loose-token" ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_not_contain ~tag:"loose sk token" line "sk-proj-loose-token";
  must_contain ~tag:"still redacted" line "[REDACTED]"

let () =
  test_off_is_noop ();
  test_on_emits_one_line ();
  test_json_shape ();
  test_defaults_are_null ();
  test_writer_exception_is_swallowed ();
  test_multiple_calls_each_line ();
  test_argv_redaction ();
  test_header_values_are_redacted_by_position ();
  test_a_header_argument_without_a_name_falls_back_to_shapes ();
  print_endline "[test_exec_tap] all tests passed"
