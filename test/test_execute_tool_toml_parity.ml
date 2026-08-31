(** Byte-identity pins for the execute tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.typed_execute_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    One tool, twelve levels deep. The OCaml builders carried a [prose] type
    that decided per call site whether a nested repeat restates its
    description; in TOML that decision is simply what the file says, so the
    type has nothing left to enforce.

    Three values moved rather than being pinned. Twenty path fields declared
    [minLength] as 1.0 while a twenty-first declared it as 1, and every
    [minProperties] (12 of them) and [maxProperties] (12) was a float too.
    JSON Schema says all three are non-negative integers, so the floats were
    wrong on both counts -- against the spec and, for minLength, against its
    own sibling twenty lines away. Nothing in TOML writes a float the loader
    would accept there, so the migration corrects them and this expectation
    carries the corrected values. Nothing else moved.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|tool_execute|}, {|Execute a typed process invocation inside the Keeper sandbox. Accepted fields: argv, pipeline, script, shell, env, cwd, timeout_sec, stdin, stdout, stderr. Provide exactly one of: a non-empty argv process vector, an explicit pipeline of typed stages, or a script command line run by a real shell in the sandbox; this tool does not expose background task lifecycle tools. The cmd and command string fields are rejected. Shell metacharacters in argv are data, not syntax; use typed stdin/stdout/stderr objects for redirection and the pipeline field for pipelines. Use Grep for structured file-content search. cwd must resolve inside the Keeper path jail. Pass a relative cwd (typically '.') and relative filesystem operands, which resolve against cwd. The Keeper-visible absolute root is informational; Docker host absolute paths are unavailable. MASC does not interpret program or subcommand meaning: after typed lowering, path containment, sandbox resolution, and the external-effect Gate, the invoked program owns its syntax and exit result.|}, {|{"additionalProperties":false,"oneOf":[{"description":"Single-process form: include one non-empty 'argv'. DO NOT also include 'pipeline' in the same call.","not":{"required":["pipeline"]},"required":["argv"]},{"description":"Pipeline form: include 'pipeline' array of exec stages.  DO NOT also include top-level 'argv' in the same call.","not":{"required":["argv"]},"required":["pipeline"]},{"description":"Shell form: include 'script'.  DO NOT also include 'argv' or 'pipeline' in the same call.","not":{"anyOf":[{"required":["argv"]},{"required":["pipeline"]}]},"required":["script"]}],"properties":{"argv":{"description":"Non-empty process vector: argv[0] is the executable and remaining tokens are arguments, all passed verbatim. There is no shell, so a literal '|', '&&' or '>' token is data, not an operator, and wildcards (*, ?, [...]) are not expanded: 'foo*.ml' names a file called 'foo*.ml'. Use script for a line you would have given a shell, or pipeline, then and the redirect fields to say the same thing field by field, and pass exact paths. Filesystem arguments use the selected sandbox namespace; relative operands resolve against the typed cwd, and Docker cannot reach host absolute paths.","items":{"type":"string"},"minItems":1,"type":"array"},"cwd":{"description":"Working directory for the command, and the only way to set one: there is no shell, so 'cd' runs as a program, changes the directory of a child that exits, and reports success having done nothing. Must stay within the keeper sandbox or an explicit allowed path. Pass a relative cwd, typically '.'. The Keeper-visible absolute root is informational, not a cwd input. Docker host absolute paths are unavailable.","type":"string"},"env":{"additionalProperties":{"type":"string"},"description":"Optional typed environment bindings. Keys must be [A-Za-z0-9_]+ and values are strings.","type":"object"},"pipeline":{"description":"Typed pipeline form: ordered exec stages. Use this instead of putting '|' in argv. Each stage may carry its own stdin/stdout/stderr, so piping and redirecting combine in one call. Stage argv uses the selected sandbox namespace, and relative path operands resolve against the typed cwd. Mutually exclusive with top-level argv.","items":{"additionalProperties":false,"properties":{"argv":{"description":"Same shape as the top-level argv. Still no shell: '|', '&&' and '>' are data, and wildcards are not expanded.","items":{"type":"string"},"minItems":1,"type":"array"},"stderr":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"},"stdin":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"discard":{"type":"boolean"},"file":{"minLength":1,"pattern":"^/.*$","type":"string"},"literal":{"description":"The bytes themselves, fed to the child's stdin without touching the filesystem — what a heredoc is. Use this to pipe a patch, a script body, or any inline input; mutually exclusive with discard and file.","type":"string"}},"type":"object"},"stdout":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"}},"required":["argv"],"type":"object"},"type":"array"},"script":{"description":"Shell form: one command line, run by a real shell inside your sandbox. Write whatever a shell takes -- pipes, '&&', ';', redirections, $(...), loops. Use this instead of putting a script in argv as 'bash -c'; that spelling is read as this field. Mutually exclusive with 'argv' and 'pipeline'. Prefer 'argv' or 'pipeline' when you do not need a shell: they run the program directly, so nothing is word-split or expanded.","minLength":1,"type":"string"},"shell":{"default":"sh","description":"Which shell runs 'script'. Defaults to 'sh'. Name 'bash' when the script uses bash-only syntax; a container's 'sh' is often dash. Ignored unless 'script' is present.","enum":["sh","bash","zsh","dash","ksh"],"type":"string"},"stderr":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"description":"Absolute path to add to, the typed form of '>>'.","minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"description":"Send this stream into another of the stage's output descriptors, the typed form of '2>&1'. The two streams are captured separately and joined afterwards, so the merged text is grouped by stream, not ordered by time.","enum":[1,2],"type":"integer"},"truncate":{"description":"Absolute path to replace, the typed form of '>'.","minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"},"stdin":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"discard":{"type":"boolean"},"file":{"description":"Absolute path to read from, the typed form of '<'.","minLength":1,"pattern":"^/.*$","type":"string"},"literal":{"description":"The bytes themselves, fed to the child's stdin without touching the filesystem — what a heredoc is. Use this to pipe a patch, a script body, or any inline input; mutually exclusive with discard and file.","type":"string"}},"type":"object"},"stdout":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"description":"Absolute path to add to, the typed form of '>>'.","minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"description":"Send this stream into another of the stage's output descriptors, the typed form of '2>&1'. The two streams are captured separately and joined afterwards, so the merged text is grouped by stream, not ordered by time.","enum":[1,2],"type":"integer"},"truncate":{"description":"Absolute path to replace, the typed form of '>'.","minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"},"then":{"description":"Programs to run after this one, each guarded by how the one before it ended, the typed form of '&&' and '||'. Use this instead of putting those operators in argv, where nothing reads them. Guards apply left to right.","items":{"additionalProperties":false,"properties":{"argv":{"description":"Same shape as the top-level argv. Still no shell: '|', '&&' and '>' are data, and wildcards are not expanded.","items":{"type":"string"},"minItems":1,"type":"array"},"on":{"enum":["success","failure"],"type":"string"},"pipeline":{"items":{"additionalProperties":false,"properties":{"argv":{"description":"Same shape as the top-level argv. Still no shell: '|', '&&' and '>' are data, and wildcards are not expanded.","items":{"type":"string"},"minItems":1,"type":"array"},"stderr":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"},"stdin":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"discard":{"type":"boolean"},"file":{"minLength":1,"pattern":"^/.*$","type":"string"},"literal":{"description":"The bytes themselves, fed to the child's stdin without touching the filesystem — what a heredoc is. Use this to pipe a patch, a script body, or any inline input; mutually exclusive with discard and file.","type":"string"}},"type":"object"},"stdout":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"}},"required":["argv"],"type":"object"},"type":"array"},"stderr":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"},"stdin":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"discard":{"type":"boolean"},"file":{"minLength":1,"pattern":"^/.*$","type":"string"},"literal":{"description":"The bytes themselves, fed to the child's stdin without touching the filesystem — what a heredoc is. Use this to pipe a patch, a script body, or any inline input; mutually exclusive with discard and file.","type":"string"}},"type":"object"},"stdout":{"additionalProperties":false,"maxProperties":1,"minProperties":1,"properties":{"append":{"minLength":1,"pattern":"^/.*$","type":"string"},"discard":{"type":"boolean"},"fd":{"enum":[1,2],"type":"integer"},"truncate":{"minLength":1,"pattern":"^/.*$","type":"string"}},"type":"object"}},"required":["on"],"type":"object"},"type":"array"},"timeout_sec":{"description":"Explicit subprocess wall-clock timeout in seconds. When absent it is 600, so name one for a command that legitimately runs longer, such as a whole test suite. A call that runs out of time is stopped and says so; it does not continue in the background.","exclusiveMinimum":0.0,"type":"number"}},"type":"object"}|}
    ]
;;

let published = Tool_shard_types.typed_execute_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.typed_execute_tools")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.typed_execute_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "execute_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
