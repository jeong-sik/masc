(* RFC tools-as-shell-commands — the shell-side of the conversion.

   A stage whose program is the bare reserved word [masc] and whose leading
   arguments walk a tool's declared [shell_command] path is not a process:
   its execution is delegated to the tool runtime, and the Shell IR
   connectors (;, &&, ||) sequence it like any other stage — the provider
   round trip the stage used to cost is gone.

   The reservation is closed at one point.  [masc] is matched by bare
   equality only, the reachable tools are exactly those that declared a
   [shell_command] in their own TOML, and the PR-1 surface is read-only
   tools — a tool that defers or needs approval answers "call the tool
   directly" rather than holding a shell line hostage.

   This module stays out of the runtime's dependency cycle by taking the
   two runtime abilities it needs as closures: how to look a descriptor up
   by name, and how to dispatch one.  [Keeper_tool_runtime] supplies both
   when it calls {!rewrite}; nothing here names it. *)

open Masc_exec

let reserved_command = "masc"

(* How the caller reaches a tool.  Deliberately the shape of the runtime's
   own dispatch, so the injecting module passes its handler unchanged. *)
type dispatch =
  descriptor:Keeper_tool_descriptor.t ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t option

let ( let* ) = Result.bind

(* {1 Declaration table} *)

(* One parse of the embedded tool tree, on first ask — the files are
   crunched into the binary, so a second parse reads the same bytes to
   the same answer (the pattern [Tool_loading_declarations] set). *)
let entries : (string list * string) list Lazy.t =
  lazy
    (List.filter_map
       (fun path ->
          match Filename.dirname path, Filename.extension path with
          | "tools", ".toml" -> (
            let name = Filename.remove_extension (Filename.basename path) in
            match Embedded_config.read path with
            | None -> None
            | Some contents -> (
              (* A file that fails to load here already made the loading
                 declarations table raise; that owner owns load failures. *)
              match Tool_definition_toml.load ~name ~contents with
              | Error _ -> None
              | Ok loaded ->
                loaded.Tool_definition_toml.shell_command
                |> Option.map (fun words -> words, name)))
          | _, _ -> None)
       Embedded_config.file_list)

(* {1 argv to tool arguments} *)

(* Every word literal, or nothing.  A word carrying an expansion or a
   concat does not name a tool path — stdlib has no traverse for this. *)
let rec literal_words = function
  | [] -> Some []
  | Shell_ir.Lit (text, _) :: rest ->
    Option.bind (literal_words rest) (fun rest -> Some (text :: rest))
  | Shell_ir.Var _ :: _ | Shell_ir.Concat _ :: _ -> None

(* Positional words land on the schema's required parameters, in the order
   the schema states them.  A schema with no [required] key states zero
   required parameters — a tool with only optional parameters takes the
   path alone, which is how [board list] and [time now] answer. *)
let required_param_names ~(descriptor : Keeper_tool_descriptor.t) :
    string list =
  let rec lookup = function
    | [] -> []
    | (key, value) :: rest -> (
      match key with
      | "required" -> (
        match value with
        | `List names ->
          List.filter_map
            (function `String name -> Some name | _ -> None)
            names
        | _ -> lookup rest)
      | _ -> lookup rest)
  in
  match descriptor.Keeper_tool_descriptor.input_schema with
  | `Assoc fields -> lookup fields
  | _ -> []

let args_json_of_words ~(descriptor : Keeper_tool_descriptor.t) words =
  let required = required_param_names ~descriptor in
  let wanted = List.length required and given = List.length words in
  if wanted <> given
  then
    Error
      (Printf.sprintf "shell command takes %d argument%s, got %d" wanted
         (if wanted = 1 then "" else "s")
         given)
  else
    Ok
      (`Assoc
         (List.map2
            (fun name word -> name, `String word)
            required words))

(* {1 The caller} *)

(* What a tool's answer looks like as a process: the disposition decides
   the exit status, the raw output rides the stream its side says.  A
   deferring tool exits non-zero with the instruction to call it directly
   — the connector then treats it as a failure, which is the stated
   mapping: deferral is never a success the next stage may build on. *)
let caller ~(dispatch : dispatch) ~(descriptor : Keeper_tool_descriptor.t)
      (args_json : Yojson.Safe.t)
  : Sandbox_target.runner =
 fun ~on_stdout_chunk ~on_stderr_chunk ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
  match dispatch ~descriptor ~args:args_json with
  | None ->
    ( Unix.WEXITED 1
    , ""
    , "shell command: the tool runtime returned no execution" )
  | Some execution -> (
    match execution.Keeper_tool_execution.disposition with
    | Tool_result.Completed _ ->
      let stdout = execution.Keeper_tool_execution.raw_output in
      (match on_stdout_chunk with Some emit -> emit stdout | None -> ());
      (Unix.WEXITED 0, stdout, "")
    | Tool_result.Failed _ ->
      let stderr = execution.Keeper_tool_execution.raw_output in
      (match on_stderr_chunk with Some emit -> emit stderr | None -> ());
      (Unix.WEXITED 1, "", stderr)
    | Tool_result.Deferred _ ->
      ( Unix.WEXITED 1
      , ""
      , Printf.sprintf
          "shell command: %s defers; call the tool directly to await it"
          descriptor.Keeper_tool_descriptor.public_name ))

(* {1 The rewrite} *)

(* Splits a [masc <path...> <args...>] word list against the declaration
   table.  Longer declared paths win over shorter ones, so a future
   [board] cannot shadow a declared [board post get]. *)
let split_words (words : string list) : (string * string list) option =
  let rec starts_with path words =
    match (path, words) with
    | [], rest -> Some rest
    | _, [] -> None
    | p :: path_rest, w :: word_rest when String.equal p w ->
      starts_with path_rest word_rest
    | _, _ -> None
  in
  let paths =
    Lazy.force entries
    |> List.map fst
    |> List.sort (fun a b -> compare (List.length b) (List.length a))
  in
  let rec try_path = function
    | [] -> None
    | path :: rest -> (
      match starts_with path words with
      | Some argument_words -> (
        match List.assoc_opt path (Lazy.force entries) with
        | Some tool -> Some (tool, argument_words)
        | None -> try_path rest)
      | None -> try_path rest)
  in
  try_path paths

(* A masc stage cannot run inside a pipeline in PR-1: dispatch would fall
   back to per-stage chaining — PR-2's native-chain semantics — before
   those semantics were settled.  Nested shapes are visited too, because
   the grammar never builds them but the type allows them. *)
let rec contains_masc (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple simple ->
    String.equal (Exec_program.to_string simple.Shell_ir.bin) reserved_command
  | Shell_ir.Pipeline stages -> List.exists contains_masc stages
  | Shell_ir.Sequence { head; tail } ->
    contains_masc head
    || List.exists (fun (_, part) -> contains_masc part) tail

let rec rewrite ~(lookup : string -> Keeper_tool_descriptor.t option)
      ~(dispatch : dispatch) (ir : Shell_ir.t)
  : (Shell_ir.t, string) result =
  match ir with
  | Shell_ir.Sequence { head; tail } ->
    let* head = rewrite ~lookup ~dispatch head in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (connector, part) :: rest ->
        let* part = rewrite ~lookup ~dispatch part in
        loop ((connector, part) :: acc) rest
    in
    let* tail = loop [] tail in
    Ok (Shell_ir.Sequence { head; tail })
  | Shell_ir.Pipeline _ when contains_masc ir ->
    Error "a masc stage cannot join a pipeline yet; run the stages separately"
  | Shell_ir.Pipeline stages ->
    let rewrites = List.map (rewrite ~lookup ~dispatch) stages in
    let rec collect acc = function
      | [] -> Ok (Shell_ir.Pipeline (List.rev acc))
      | stage :: rest -> (
        match stage with
        | Error message -> Error message
        | Ok rewritten -> collect (rewritten :: acc) rest)
    in
    collect [] rewrites
  | Shell_ir.Simple simple -> (
    if
      not
        (String.equal
           (Exec_program.to_string simple.Shell_ir.bin)
           reserved_command)
    then Ok ir
    else if simple.Shell_ir.env <> []
    then Error "a masc stage carries no environment prefix; pass tool arguments as words"
    else if simple.Shell_ir.redirects <> []
    then Error "a masc stage takes no redirects; the tool answers with text"
    else
      match literal_words simple.Shell_ir.args with
      | None ->
        Error "a masc stage's words must be literal; expansions stay on the direct tool call"
      | Some words -> (
        let spoken = if words = [] then "(no arguments)" else String.concat " " words in
        match split_words words with
        | None ->
          Error
            (Printf.sprintf
               "no tool on this turn's shell surface answers %s; each tool declares its own path"
               spoken)
        | Some (tool_name, argument_words) -> (
          match lookup tool_name with
          | None ->
            Error
              (Printf.sprintf
                 "%s declares a shell path but has no descriptor this turn"
                 tool_name)
          | Some descriptor ->
            (* A shell path on the Execute handler itself would recurse:
               rewrite → dispatch → Execute → rewrite.  No such
               declaration exists today; this guard keeps it a named
               refusal instead of a loop the day one appears. *)
            if
              descriptor.Keeper_tool_descriptor.runtime_handler
              = Keeper_tool_descriptor.Tool_execute
            then
              Error
                (Printf.sprintf
                   "%s runs commands, so it cannot be a shell command itself"
                   tool_name)
            else
              let* args_json = args_json_of_words ~descriptor argument_words in
              let tool_caller = caller ~dispatch ~descriptor args_json in
              Ok
                (Shell_ir.Simple
                   { simple with
                     Shell_ir.sandbox = Sandbox_target.delegated ~caller:tool_caller ()
                   }))))
