(** Tests for {!Keeper_context_window} (RFC keeper-context-window-in-tokens).

    The window is declared in tokens and the cut measures bytes; the bridge
    is a density observed from one request. These pin the arithmetic, the
    source bookkeeping a shrink leaves behind, and the observation table's
    refusal to record a non-measurement. *)

module Window = Masc.Keeper_context_window

open Alcotest

let density ~input_tokens ~measured_bytes : Window.density =
  { input_tokens; measured_bytes }
;;

(* 85K tokens against a request that measured 400,000 bytes for 100,000
   tokens: four bytes per token, so the window is 340,000 bytes. *)
let test_capacity_is_the_window_read_through_the_density () =
  match
    Window.capacity
      (Window.declared ~window_tokens:85_000)
      (Some (density ~input_tokens:100_000 ~measured_bytes:400_000))
  with
  | Window.Measured { capacity_bytes; window_tokens; _ } ->
    check int "window tokens carried" 85_000 window_tokens;
    check int "capacity bytes" 340_000 capacity_bytes
  | Window.Unmeasured _ -> fail "a density was supplied"
;;

let test_no_density_is_unmeasured_not_a_guess () =
  match Window.capacity (Window.declared ~window_tokens:85_000) None with
  | Window.Unmeasured { window_tokens } -> check int "window tokens carried" 85_000 window_tokens
  | Window.Measured _ -> fail "no density was supplied"
;;

let test_tokens_of_bytes_inverts_the_density () =
  let d = density ~input_tokens:100_000 ~measured_bytes:400_000 in
  check int "400,000 bytes read as 100,000 tokens" 100_000 (Window.tokens_of_bytes d 400_000);
  check int "a reserve of 40,000 bytes is 10,000 tokens" 10_000 (Window.tokens_of_bytes d 40_000)
;;

(* A halved window keeps the declaration beside it, and returning to the
   declared size is [Declared] again rather than a shrink of itself. *)
let test_with_tokens_keeps_the_declaration_visible () =
  let declared = Window.declared ~window_tokens:85_000 in
  let shrunk = Window.with_tokens declared ~window_tokens:42_500 in
  check int "shrunk size" 42_500 shrunk.Window.window_tokens;
  check int "declared size survives the shrink" 85_000 (Window.declared_tokens shrunk);
  check string "source names the shrink" "shrunk_after_overflow"
    (Window.source_to_string shrunk.Window.source);
  let restored = Window.with_tokens shrunk ~window_tokens:85_000 in
  check string "the declared size is declared again" "declared"
    (Window.source_to_string restored.Window.source);
  let twice = Window.with_tokens shrunk ~window_tokens:21_250 in
  check int "a second shrink still names the original declaration" 85_000
    (Window.declared_tokens twice)
;;

let test_to_json_carries_window_declared_and_source () =
  let shrunk = Window.with_tokens (Window.declared ~window_tokens:85_000) ~window_tokens:42_500 in
  match Window.to_json shrunk with
  | `Assoc fields ->
    check (option int) "window_tokens" (Some 42_500)
      (match List.assoc_opt "window_tokens" fields with Some (`Int n) -> Some n | _ -> None);
    check (option int) "declared_tokens" (Some 85_000)
      (match List.assoc_opt "declared_tokens" fields with Some (`Int n) -> Some n | _ -> None);
    check (option string) "source" (Some "shrunk_after_overflow")
      (match List.assoc_opt "source" fields with Some (`String s) -> Some s | _ -> None)
  | _ -> fail "to_json must be an object"
;;

(* {1 Density table} *)

let test_density_starts_unobserved_and_records_the_newest () =
  Eio_main.run
  @@ fun _env ->
  Window.Density.For_testing.reset ();
  check bool "nothing observed yet" true
    (Option.is_none (Window.Density.lookup ~runtime_id:"glm-coding.glm-5.3-flash"));
  Window.Density.observe
    ~runtime_id:"glm-coding.glm-5.3-flash"
    ~measured_bytes:400_000
    ~input_tokens:100_000;
  Window.Density.observe
    ~runtime_id:"glm-coding.glm-5.3-flash"
    ~measured_bytes:300_000
    ~input_tokens:90_000;
  (match Window.Density.lookup ~runtime_id:"glm-coding.glm-5.3-flash" with
   | Some { Window.input_tokens; measured_bytes } ->
     check int "newest tokens" 90_000 input_tokens;
     check int "newest bytes" 300_000 measured_bytes
   | None -> fail "observed twice");
  check bool "another runtime is unaffected" true
    (Option.is_none (Window.Density.lookup ~runtime_id:"kimi_coding.kimi-k3"))
;;

(* A provider that reported no prompt tokens, or a request that measured
   nothing, is not an observation: recording it would divide by zero or read
   every later window as empty. *)
let test_density_ignores_a_non_measurement () =
  Eio_main.run
  @@ fun _env ->
  Window.Density.For_testing.reset ();
  Window.Density.observe ~runtime_id:"r" ~measured_bytes:0 ~input_tokens:100;
  Window.Density.observe ~runtime_id:"r" ~measured_bytes:100 ~input_tokens:0;
  check bool "neither was recorded" true (Option.is_none (Window.Density.lookup ~runtime_id:"r"))
;;

let () =
  run
    "keeper_context_window"
    [ ( "capacity"
      , [ test_case "capacity is the window read through the density" `Quick
            test_capacity_is_the_window_read_through_the_density
        ; test_case "no density is unmeasured, not a guess" `Quick
            test_no_density_is_unmeasured_not_a_guess
        ; test_case "tokens_of_bytes inverts the density" `Quick
            test_tokens_of_bytes_inverts_the_density
        ] )
    ; ( "source"
      , [ test_case "with_tokens keeps the declaration visible" `Quick
            test_with_tokens_keeps_the_declaration_visible
        ; test_case "to_json carries window, declared and source" `Quick
            test_to_json_carries_window_declared_and_source
        ] )
    ; ( "density"
      , [ test_case "starts unobserved and records the newest" `Quick
            test_density_starts_unobserved_and_records_the_newest
        ; test_case "ignores a non-measurement" `Quick
            test_density_ignores_a_non_measurement
        ] )
    ]
;;
