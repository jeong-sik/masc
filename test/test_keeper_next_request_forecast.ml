(* The forecast runs the turn's own cut forward. These cases pin the
   arithmetic on a synthetic history so the numbers are checkable by hand:
   the capacity minus the prompt's fixed parts is what the history may fill,
   the newest atom is never dropped, and a runtime with no density yet gets
   the smallest request that carries the turn. *)

open Masc

let message role text : Agent_core.Types.message =
  { role; content = [ Agent_core.Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

(* One user/assistant exchange per index, each side [n] bytes of text. *)
let history ~exchanges ~text_bytes =
  List.concat_map
    (fun index ->
      let text = String.make text_bytes (Char.chr (Char.code 'a' + (index mod 26))) in
      [ message Agent_core.Types.User text; message Agent_core.Types.Assistant text ])
    (List.init exchanges Fun.id)

let measured ~capacity_bytes =
  Keeper_context_window.Measured
    { window_tokens = 1000
    ; density = { input_tokens = 1000; measured_bytes = capacity_bytes }
    ; capacity_bytes
    }

let atom_bytes messages =
  List.fold_left (fun sum m -> sum + Keeper_next_request_forecast.measure m) 0 messages

let test_the_fixed_parts_come_off_the_capacity_first () =
  let messages = history ~exchanges:100 ~text_bytes:100 in
  let per_atom = atom_bytes (history ~exchanges:1 ~text_bytes:100) / 2 in
  let total_atoms = 200 in
  (* Room for 90 atoms after the prompt's fixed parts. The cut drops atoms
     in multiples of 60 so the transmitted prefix stays byte-identical while
     the conversation grows: dropping 60 leaves 140, too many; dropping 120
     leaves 80, which fits. So 80 travel. *)
  let capacity_bytes = (90 * per_atom) + 5_000 + 7_000 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(measured ~capacity_bytes)
      ~reserved_bytes:5_000
      ~pinned_bytes:7_000
      messages
  with
  | Keeper_next_request_forecast.Cut { kept_atoms; fit; _ } ->
    Alcotest.(check int) "eighty of two hundred atoms fit under the fixed parts" 80 kept_atoms;
    Alcotest.(check bool) "and the request is within the window" true
      (match fit with
       | Runtime_model_input_tail_window.Within_target -> true
       | Runtime_model_input_tail_window.Overrun _ -> false);
    Alcotest.(check bool) "the history was larger than that" true (total_atoms > kept_atoms)
  | Keeper_next_request_forecast.Newest_atom_only _ ->
    Alcotest.fail "a measured capacity cuts, it does not fall to the newest atom"

let test_fixed_parts_above_the_capacity_keep_the_newest_atom () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(measured ~capacity_bytes:1_000)
      ~reserved_bytes:800
      ~pinned_bytes:800
      messages
  with
  | Keeper_next_request_forecast.Cut { kept_atoms; fit; _ } ->
    Alcotest.(check int) "the newest atom still travels" 1 kept_atoms;
    Alcotest.(check bool) "and the overrun names the fixed parts" true
      (match fit with
       | Runtime_model_input_tail_window.Overrun
           { cause = Runtime_model_input_tail_window.Fixed_parts_exceed_target; _ } -> true
       | Runtime_model_input_tail_window.Overrun
           { cause = Runtime_model_input_tail_window.Newest_atom_exceeds_target; _ }
       | Runtime_model_input_tail_window.Within_target -> false)
  | Keeper_next_request_forecast.Newest_atom_only _ ->
    Alcotest.fail "a measured capacity reports an overrun, not an unmeasured floor"

let test_no_density_sends_the_newest_atom_only () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(Keeper_context_window.Unmeasured { window_tokens = 85_000 })
      ~reserved_bytes:5_000
      ~pinned_bytes:7_000
      messages
  with
  | Keeper_next_request_forecast.Newest_atom_only { transmitted_bytes } ->
    Alcotest.(check bool) "the floor carries the newest atom's bytes" true
      (transmitted_bytes > 0 && transmitted_bytes < atom_bytes messages)
  | Keeper_next_request_forecast.Cut _ ->
    Alcotest.fail "an unmeasured runtime has no capacity to cut against"

let () =
  Alcotest.run "keeper_next_request_forecast"
    [ ( "cut"
      , [ Alcotest.test_case "the fixed parts come off the capacity first" `Quick
            test_the_fixed_parts_come_off_the_capacity_first
        ; Alcotest.test_case "fixed parts above the capacity keep the newest atom" `Quick
            test_fixed_parts_above_the_capacity_keep_the_newest_atom
        ; Alcotest.test_case "no density sends the newest atom only" `Quick
            test_no_density_sends_the_newest_atom_only
        ] )
    ]
