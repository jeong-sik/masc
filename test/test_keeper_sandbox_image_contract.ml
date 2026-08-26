(** Every tool a keeper reaches for is provided by the sandbox image, or the
    image says why it is not.

    The image shipped npm and no pnpm while 103 measured tool calls ran through
    pnpm; it shipped [timeout] while 14 calls asked for [gtimeout]; it had no
    [ps], [pgrep] or [pkill] while a keeper used them to recover a stuck build.
    None of that surfaced until a keeper moved onto the docker profile and
    failed, because nothing compared what the image installs against what
    keepers run.

    This is that comparison. The measured list below is the command-position
    frequency over 35,919 filesystem tool calls (2026-08-20..26), and every
    entry has to be in exactly one of two buckets. A tool in neither fails the
    test, which is the point: a new dependency cannot arrive unclassified.

    Matching is on whole tokens, not substrings. The Dockerfile is split on
    whitespace and path separators, so ["fd"] is found in
    ["/usr/local/bin/fd"] but ["fd"] would not be found inside ["fd-find"]
    alone -- both are listed where both are meant. *)

open Alcotest

let dockerfile_path = "Dockerfile.keeper-sandbox"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    In_channel.input_all ic)
;;

(* Comments are dropped before tokenizing, and this is load-bearing. The first
   version of this test searched the whole file, and the prose below the apt
   list -- which names procps to explain why it was added -- satisfied the
   check on its own. Deleting procps from the install list left the test green.

   A name mentioned in prose is not an installed package. Only instruction
   lines count. *)
let instruction_lines text =
  String.split_on_char '\n' text
  |> List.filter (fun line ->
    let trimmed = String.trim line in
    not (String.length trimmed > 0 && trimmed.[0] = '#'))
  |> String.concat "\n"
;;

(* Whole-token split: whitespace plus the separators that appear inside the
   install and symlink lines. A path token contributes its basename too, which
   is how a symlinked command counts as provided. *)
let tokens text =
  let is_sep = function
    | ' ' | '\t' | '\n' | '\r' | '/' | '\\' | '"' | '\'' | '=' | ':' | ',' -> true
    | _ -> false
  in
  let out = ref [] in
  let buf = Buffer.create 32 in
  let flush () =
    if Buffer.length buf > 0
    then begin
      out := Buffer.contents buf :: !out;
      Buffer.clear buf
    end
  in
  String.iter (fun c -> if is_sep c then flush () else Buffer.add_char buf c) text;
  flush ();
  List.sort_uniq String.compare !out
;;

let has token set = List.exists (String.equal token) set

(* (command a keeper runs, the Dockerfile token that supplies it).

   The pair is the documentation: [("pgrep", "procps")] says the apt package
   name is not the command name, which is exactly the mistake that left ps and
   pgrep out while the list looked complete. *)
let provided =
  [ "git", "git"
  ; "bash", "bash"
  ; "gh", "gh"
  ; "python3", "python3"
  ; "rg", "ripgrep"
  ; "node", "nodejs"
  ; "npm", "npm"
  ; "jq", "jq"
  ; "rsync", "rsync"
  ; "curl", "curl"
  ; "make", "make"
  ; "patch", "patch"
  ; "unzip", "unzip"
    (* measured gaps this change closes *)
  ; "pnpm", "pnpm"
  ; "pgrep", "procps"
  ; "pkill", "procps"
  ; "ps", "procps"
  ; "lsof", "lsof"
  ; "zsh", "zsh"
  ; "trash", "trash-cli"
  ; "shasum", "perl"
  ; "gtimeout", "gtimeout"
  ; "fd", "fd-find"
  ]
;;

(* Absent on purpose. The image has to say so in prose, because the next reader
   will otherwise add them back -- and for [docker] that would hand the
   container the daemon and make every mount boundary in the file advisory.

   The host wrappers [masc] and [sb] are not on this list. They are not tools
   an image could install, and their names collide with legitimate content:
   the file copies [masc.opam] through /tmp/masc/, so asserting "masc never
   appears in an instruction line" fails on a path that has nothing to do with
   the operator's CLI. The prose above still names them; a test that cannot
   distinguish the two things should not claim to. *)
let deliberately_absent = [ "docker"; "playwright"; "ttyd"; "md5" ]

let test_provided_tools_are_installed () =
  let set = tokens (instruction_lines (read_file dockerfile_path)) in
  List.iter
    (fun (command, provider) ->
       check
         bool
         (Printf.sprintf "%s comes from %s" command provider)
         true
         (has provider set))
    provided
;;

let test_absent_tools_carry_a_reason () =
  let text = read_file dockerfile_path in
  let everywhere = tokens text in
  let instructions = tokens (instruction_lines text) in
  List.iter
    (fun command ->
       check
         bool
         (Printf.sprintf "%s is explained in prose" command)
         true
         (has command everywhere);
       check
         bool
         (Printf.sprintf "%s is not quietly installed anyway" command)
         false
         (has command instructions))
    deliberately_absent
;;

(* A command cannot be both shipped and refused. *)
let test_the_two_buckets_are_disjoint () =
  List.iter
    (fun (command, _) ->
       check
         bool
         (Printf.sprintf "%s is not also on the absent list" command)
         false
         (has command deliberately_absent))
    provided
;;

(* The anti-drift property. Measured command-position frequency; every entry
   has to be classified, so a new dependency forces a decision instead of
   surfacing as a container failure later. *)
let measured_usage =
  [ "git", 8210
  ; "bash", 4651
  ; "gh", 3393
  ; "python3", 1876
  ; "rg", 876
  ; "node", 786
  ; "jq", 108
  ; "curl", 126
  ; "pnpm", 103
  ; "trash", 39
  ; "ps", 20
  ; "playwright", 15
  ; "gtimeout", 14
  ; "shasum", 12
  ; "pgrep", 11
  ; "docker", 11
  ; "ttyd", 8
  ; "lsof", 7
  ; "pkill", 4
  ; "md5", 4
  ; "zsh", 3
  ; "fd", 2
  ]
;;

let test_every_measured_tool_is_classified () =
  List.iter
    (fun (command, uses) ->
       let shipped = List.exists (fun (c, _) -> String.equal c command) provided in
       let refused = has command deliberately_absent in
       check
         bool
         (Printf.sprintf
            "%s (%d uses) is either shipped or refused, not unclassified"
            command
            uses)
         true
         (shipped || refused))
    measured_usage
;;

let () =
  run
    "keeper sandbox image contract"
    [ ( "the image"
      , [ test_case "provided tools are installed" `Quick test_provided_tools_are_installed
        ; test_case "absent tools carry a reason" `Quick test_absent_tools_carry_a_reason
        ; test_case "the two buckets are disjoint" `Quick test_the_two_buckets_are_disjoint
        ; test_case
            "every measured tool is classified"
            `Quick
            test_every_measured_tool_is_classified
        ] )
    ]
;;
