(** Every prompt shipped in [config/prompts] renders with the variables its own
    frontmatter declares.

    Two layers made a broken prompt survive silently. [get_prompt] answers the
    empty string for a key it cannot find, and the startup check
    ([Server_runtime_bootstrap], via [validate_prompt_templates]) logs an error
    and boots anyway. So a renamed file, a placeholder the frontmatter does not
    declare, or a declared variable the template never uses shipped as a
    quietly shorter prompt — the model simply received less instruction, and no
    test or boot failure said so.

    This makes the whole prompt directory a CI gate instead: every key resolves,
    every declared variable is consumed, and every placeholder in the body is
    declared. *)

open Alcotest

let prompt_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

let load () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ()
;;

(* A value distinctive enough that finding it proves the template placed this
   variable, rather than the word appearing in the template's own prose. *)
let marker name = Printf.sprintf "@@VAR_%s@@" name

let key_and_variables item =
  match item with
  | `Assoc fields ->
    let key =
      match List.assoc_opt "key" fields with
      | Some (`String key) -> key
      | _ -> failf "prompt listing entry has no key: %s" (Yojson.Safe.to_string item)
    in
    let variables =
      match List.assoc_opt "template_variables" fields with
      | Some (`List values) ->
        List.filter_map
          (function
            | `String name -> Some name
            | _ -> None)
          values
      | _ -> []
    in
    (key, variables)
  | other -> failf "prompt listing entry is not an object: %s" (Yojson.Safe.to_string other)
;;

let test_every_prompt_renders () =
  load ();
  let prompts = Prompt_registry.list_prompts () in
  check bool "the prompt directory is not empty" true (prompts <> []);
  List.iter
    (fun item ->
       let key, variables = key_and_variables item in
       check
         bool
         (key ^ ": resolves from a real source")
         true
         (not (String.equal (Prompt_registry.prompt_source key) "missing"));
       let vars = List.map (fun name -> (name, marker name)) variables in
       match Prompt_registry.render_prompt_template key vars with
       | Error detail -> failf "%s: does not render: %s" key detail
       | Ok text ->
         (* A variable the frontmatter declares and the body never uses is the
            shape that let a computed section vanish: the caller keeps building
            it and the template keeps ignoring it. *)
         List.iter
           (fun name ->
              check
                bool
                (Printf.sprintf "%s: declared variable %s is used by the body" key name)
                true
                (Astring.String.is_infix ~affix:(marker name) text))
           variables)
    prompts
;;

(* Same invariant the boot gate enforces, decided here instead of at the first
   start after a release: every prompt markdown file the repo ships registers as
   a key. A file the loader skipped — unreadable, or with frontmatter it could
   not parse — otherwise becomes a prompt nobody notices is gone, because the
   only symptom is a shorter prompt. *)
let test_every_prompt_file_registers () =
  load ();
  let dir = prompt_dir () in
  let files =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".md")
    |> List.sort String.compare
  in
  check bool "the prompt directory ships markdown" true (files <> []);
  List.iter
    (fun file ->
       let key = Filename.remove_extension file in
       check
         bool
         (file ^ ": registers as key " ^ key)
         true
         (not (String.equal (Prompt_registry.prompt_source key) "missing")))
    files
;;

(* Boot syncs prompt assets from the binary only when the embedded file set
   and the embedded manifest agree. A fragment committed without a manifest
   line makes the whole sync refuse, and every fragment added since then is
   absent from the live prompt directory and renders nothing — the symptom is
   a shorter prompt and one boot log line. 2026-09-02: five tool_failure.*.md
   fragments shipped unlisted and took two previous_turn_stop fragments down
   with them. This pins the manifest to the directory in the source tree. *)
let test_every_prompt_file_is_in_the_managed_manifest () =
  let dir = prompt_dir () in
  let manifest_path = Filename.concat dir "managed-assets.json" in
  let listed =
    match Yojson.Safe.from_file manifest_path with
    | `Assoc fields ->
      (match List.assoc_opt "paths" fields with
       | Some (`List paths) ->
         List.filter_map (function `String p -> Some p | _ -> None) paths
       | _ -> failf "%s has no paths list" manifest_path)
    | _ -> failf "%s is not a JSON object" manifest_path
  in
  let on_disk =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
         (not (String.equal name "managed-assets.json"))
         && (not (String.starts_with ~prefix:"." name))
         && not (Sys.is_directory (Filename.concat dir name)))
  in
  let sorted = List.sort_uniq String.compare in
  check
    (list string)
    "managed-assets.json lists exactly the prompt files on disk"
    (sorted on_disk)
    (sorted listed)
;;

let test_no_template_uses_an_undeclared_variable () =
  load ();
  match Prompt_registry.validate_prompt_templates () with
  | [] -> ()
  | invalid ->
    failf
      "templates use variables their frontmatter does not declare: %s"
      (invalid
       |> List.map (fun (key, variable) -> Printf.sprintf "%s -> %s" key variable)
       |> String.concat ", ")
;;

let () =
  Alcotest.run
    "prompt_templates"
    [ ( "config/prompts"
      , [ test_case
            "every prompt renders and consumes what it declares"
            `Quick
            test_every_prompt_renders
        ; test_case
            "no template uses an undeclared variable"
            `Quick
            test_no_template_uses_an_undeclared_variable
        ; test_case
            "every prompt file registers as a key"
            `Quick
            test_every_prompt_file_registers
        ; test_case
            "every prompt file is in the managed manifest"
            `Quick
            test_every_prompt_file_is_in_the_managed_manifest
        ] )
    ]
;;
