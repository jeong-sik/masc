(* atd-native-gen: writes the Swift and Kotlin types native clients decode
   the Keeper chat wire with (RFC-native-keeper-chat-clients D2).

   usage: atd_native_gen swift FILE.atd > Generated.swift
          atd_native_gen kotlin PACKAGE FILE.atd > Generated.kt

   The output depends only on the arguments and FILE.atd. An ATD shape or
   annotation the generator does not write is an error on stderr and exit
   1; nothing is written in its place. *)

let usage = "usage: atd_native_gen (swift FILE.atd | kotlin PACKAGE FILE.atd)"

let load path =
  match Atd.Util.load_file path with
  | atd -> Atd_native.Native_ir.of_module atd
  | exception Atd.Ast.Atd_error message -> Error message

let generate path emit =
  match load path with
  | Ok defs ->
    print_string (emit ~source:(Filename.basename path) defs);
    0
  | Error message ->
    prerr_endline message;
    1

let () =
  match Sys.argv with
  | [| _; "swift"; path |] -> exit (generate path Atd_native.Swift_gen.emit)
  | [| _; "kotlin"; package; path |] ->
    if Atd_native.Kotlin_gen.valid_package package
    then exit (generate path (Atd_native.Kotlin_gen.emit ~package))
    else (
      prerr_endline ("not a Kotlin package name: " ^ package);
      exit 1)
  | _ ->
    prerr_endline usage;
    exit 2
