(* atd-native-gen: writes the Swift types native clients decode the Keeper
   chat wire with (RFC-native-keeper-chat-clients D2).

   usage: atd_native_gen swift FILE.atd > Generated.swift

   The output depends only on FILE.atd. An ATD shape or annotation the
   generator does not write is an error on stderr and exit 1; nothing is
   written in its place. *)

let usage = "usage: atd_native_gen swift FILE.atd"

let generate path =
  let atd = Atd.Util.load_file ~inherit_fields:true ~inherit_variants:true path in
  match Atd_native.Native_ir.of_module atd with
  | Ok defs ->
    print_string (Atd_native.Swift_gen.emit ~source:(Filename.basename path) defs);
    0
  | Error message ->
    prerr_endline message;
    1

let () =
  match Sys.argv with
  | [| _; "swift"; path |] -> exit (generate path)
  | _ ->
    prerr_endline usage;
    exit 2
