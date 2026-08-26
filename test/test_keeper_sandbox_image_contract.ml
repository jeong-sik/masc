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
    alone -- both are listed where both are meant.

    Presence is not the whole contract, and this file learned that twice.
    The first version searched the entire file, so the prose naming procps
    satisfied the check and deleting procps from the install list left the test
    green; comments are stripped now. The second gap is bigger: pnpm installed
    cleanly on top of apt's node 18 and answered
    ["requires at least Node.js v22.13"] when run. Present on PATH, unusable.
    A Dockerfile test cannot execute the image, so what it can check is the
    version constraint the repository states -- see {!version_pins}. *)

open Alcotest

(* Dune runs a test from its own build directory, not from the workspace root,
   so a bare relative path finds nothing. The repository already answers this
   with DUNE_SOURCEROOT plus a walk upwards, and the shape here is the one
   test_install_script.ml uses -- including the anchor check, which is what
   makes the answer trustworthy: an environment variable pointing somewhere
   without the Dockerfile in it is not the root we want.

   The loud failure at the end is deliberate. The first version of this test
   read the bare name and CI reported Sys_error("No such file or directory"),
   which reads as a missing Dockerfile rather than a test that cannot find it. *)
let dockerfile_name = "Dockerfile.keeper-sandbox"

let rec find_source_root_from dir hops =
  if hops > 8 then None
  else if Sys.file_exists (Filename.concat dir dockerfile_name) then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root_from parent (hops + 1)
;;

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root
    when String.trim root <> ""
         && Sys.file_exists (Filename.concat root dockerfile_name) -> root
  | _ ->
    (match find_source_root_from (Sys.getcwd ()) 0 with
     | Some root -> root
     | None ->
       Alcotest.fail
         (Printf.sprintf
            "could not locate %s from %s -- the test cannot read the image \
             contract it is meant to check"
            dockerfile_name
            (Sys.getcwd ())))
;;

let dockerfile_path () = Filename.concat (source_root ()) dockerfile_name

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
  (* Two shapes need both halves to be findable, so they are split as well as
     kept whole: [pnpm@10.31.0] has to answer for the tool [pnpm] and for the
     pin, and [deb.nodesource.com] for the host [nodesource]. Splitting on [@]
     and [.] wholesale would break [ya29.] style tokens elsewhere, so the extra
     pieces are added rather than the separator widened. *)
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
  let pieces =
    !out
    |> List.concat_map (fun token ->
      token
      |> String.split_on_char '@'
      |> List.concat_map (String.split_on_char '.')
      |> List.filter (fun piece -> String.length piece > 0))
  in
  List.sort_uniq String.compare (!out @ pieces)
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
let deliberately_absent = [ "docker"; "playwright"; "ttyd"; "md5"; "actionlint" ]

let test_provided_tools_are_installed () =
  let set = tokens (instruction_lines (read_file (dockerfile_path ()))) in
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
  let text = read_file (dockerfile_path ()) in
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
    (* Read out of the container exec failures rather than command-position
       frequency: these are the commands a docker keeper actually could not
       start, enumerated from the live traces of the three keepers already on
       that profile.

       dune 4, /bin/zsh 1, actionlint 1, and one _build/.../*.exe that is the
       consequence of dune failing rather than a tool of its own. Every one is
       classified above -- dune and zsh are shipped now, actionlint is refused
       with a reason. *)
  ; "actionlint", 1
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

(* Where a tool's usefulness depends on a version, the image has to name the
   version the project declares -- not "latest", which is how the node 18 /
   pnpm mismatch got in. dashboard/package.json is the source of both numbers.

   This is a manifest cross-check, not a heuristic: the pin either appears in
   an instruction line or it does not. *)
let version_pins =
  [ "pnpm@10.31.0", "dashboard/package.json declares packageManager pnpm@10.31.0"
  ; "node_22.x", "dashboard/package.json declares engines.node >= 22"
  ]
;;

let test_versions_are_pinned_to_the_project () =
  let set = tokens (instruction_lines (read_file (dockerfile_path ()))) in
  List.iter
    (fun (pin, why) ->
       check bool (Printf.sprintf "%s — %s" pin why) true (has pin set))
    version_pins
;;

(* The container runs as the host uid, which matches no account in the image, so
   the opam switch has to be traversable by "other". /home/opam ships 0750 and
   the switch below it 0755 -- the parent denies, and PATH pointing into the
   switch does not help.

   Measured 2026-08-26: without this, `${OPAM_SWITCH_PREFIX}/bin/dune` answers
   "Permission denied" as the host uid, and the live fleet shows it as
   "OCI runtime exec failed, exit 127, dune build". Five occurrences in one day
   on the keepers already running containers -- the failure was in the data
   before anyone read it as this.

   Checked as a token because that is what a Dockerfile test can see; the
   build itself asserts the outcome with `test -x`. *)
let test_the_opam_switch_is_traversable () =
  let set = tokens (instruction_lines (read_file (dockerfile_path ()))) in
  check bool "the switch parent is opened for other" true (has "o+rx" set);
  check
    bool
    "and the build fails if dune is still unreachable"
    true
    (has "opam switch bin not traversable after chmod" set
     || has "traversable" set)
;;

(* apt's nodejs is 18.19 on this base, so resolving node from apt alone cannot
   satisfy engines.node >= 22. The nodesource repository has to be present. *)
let test_node_does_not_come_from_apt_alone () =
  let set = tokens (instruction_lines (read_file (dockerfile_path ()))) in
  check
    bool
    "a signed nodesource repository supplies node"
    true
    (has "nodesource" set && has "deb.nodesource.com" set)
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
        ; test_case
            "versions are pinned to the project"
            `Quick
            test_versions_are_pinned_to_the_project
        ; test_case
            "node does not come from apt alone"
            `Quick
            test_node_does_not_come_from_apt_alone
        ; test_case
            "the opam switch is traversable"
            `Quick
            test_the_opam_switch_is_traversable
        ] )
    ]
;;
