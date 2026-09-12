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
  (* Authorization is not a descriptive header, so the whole value goes --
     the scheme word is not worth leaving credential material beside. *)
  must_contain ~tag:"redacted bearer" line "Authorization: [REDACTED]";
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

(* curl takes a short option's value attached or separated. Only the separated
   form was read as a header, so [-Hxi-api-key: ...] carried its key through. *)
let test_an_attached_header_option_is_still_a_header () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:
      [ "curl"; "-Hxi-api-key: attached-secret"; "--header=X-Api-Key: long-attached" ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_not_contain ~tag:"attached short option" line "attached-secret";
  must_not_contain ~tag:"attached long option" line "long-attached";
  must_contain ~tag:"the short form keeps its shape" line "-Hxi-api-key: [REDACTED]";
  must_contain ~tag:"and the long one too" line "--header=X-Api-Key: [REDACTED]"

(* -H is curl's header flag. rg reads it as --with-filename and takes no value,
   so reading the next argument as a header rewrote a search pattern. *)
let test_only_header_taking_commands_consume_the_next_argument () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:[ "rg"; "-H"; "TODO: fix this"; "lib" ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_contain ~tag:"the pattern is not a header value" line "TODO: fix this"

(* A value the shape rules half-recognise is still a credential. Left partial,
   "sk-live:opaque" came out as "[REDACTED]:opaque" -- unredacted, with a
   [REDACTED] beside it to look safe. *)
let test_a_partly_recognised_header_value_goes_whole () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:[ "curl"; "-H"; "X-Api-Key: sk-live:opaque-tail" ]
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_not_contain ~tag:"the opaque tail" line "opaque-tail";
  must_contain ~tag:"the whole value went" line "X-Api-Key: [REDACTED]"

(* The tap records every invocation, so an argv long enough to overflow the
   stack while preparing the record would take the process with it. *)
let test_a_long_argv_does_not_overflow () =
  let captured = ref "" in
  Exec_tap.enable ~writer:(fun line -> captured := line);
  Exec_tap.record
    ~kind:Exec_tap.Process_eio_run_argv
    ~argv:("curl" :: List.init 500_000 (fun i -> Printf.sprintf "arg-%d" i))
    ();
  let line = !captured in
  Exec_tap.disable ();
  must_contain ~tag:"the last argument survived" line "arg-499999"

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
  test_an_attached_header_option_is_still_a_header ();
  test_only_header_taking_commands_consume_the_next_argument ();
  test_a_partly_recognised_header_value_goes_whole ();
  test_a_long_argv_does_not_overflow ();
  print_endline "[test_exec_tap] all tests passed"
