(** Native posture chooses managed guidance; wording remains operator-owned.
    The app-server fixture in test_keeper_codex_blank_system_prompt checks
    that an override reaches the actual developerInstructions request. *)
open Alcotest
module Codex = Masc.Keeper_codex_runtime.For_testing
module Posture = Runtime_native_tools
module Registry = Prompt_registry
module Names = Prompt_names

let require = function Ok value -> value | Error detail -> fail detail

let test_only_read_uses_managed_guidance () =
  let key = Names.keeper_codex_native_read in
  let previous = (Registry.resolve_prompt key).override_value in
  let note = "OPERATOR_NATIVE_READ_GUIDANCE" in
  Registry.set_override key note |> require;
  Fun.protect
    ~finally:(fun () -> match previous with
      | Some value -> Registry.set_override key value |> require
      | None -> Registry.clear_prompt_override key)
    (fun () ->
      check (list string) "read carries the managed override" [note]
        (Codex.native_posture_note Posture.Native_read |> require);
      check (list string) "full carries none" []
        (Codex.native_posture_note Posture.Native_full |> require);
      check (list string) "none carries none" []
        (Codex.native_posture_note Posture.Native_none |> require))

let () =
  run "keeper codex write path note"
    [ "posture", [test_case "only read uses managed guidance" `Quick
                    test_only_read_uses_managed_guidance] ]
