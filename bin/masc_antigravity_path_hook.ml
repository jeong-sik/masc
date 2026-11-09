(* HIGH-RISK-UNREVIEWED: native read guard. It never grants a permission: "allow" delegates to
   agy's remaining hooks and settings. An unmatched outside read must return
   a tool error instead of reaching the headless Ask that ends a Keeper turn.
   Native_none's settings deny remains in force. *)

exception Invalid_input

let field key = function
  | `Assoc fields ->
    (match List.filter (fun (name, _) -> String.equal name key) fields with
     | [_, value] -> value
     | [] | _ :: _ -> raise Invalid_input)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _
  | `Tuple _ | `Variant _ -> raise Invalid_input

let string = function
  | `String value when value <> "" -> value
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _
  | `List _ | `Tuple _ | `Variant _ -> raise Invalid_input

let parts path = String.split_on_char '/' path |> List.filter (fun part -> part <> "")

let rec below root path = match root, path with
  | [], _ -> true
  | parent :: parents, child :: children -> String.equal parent child && below parents children
  | _ :: _, [] -> false

let canonical_root root =
  if Filename.is_relative root then raise Invalid_input;
  try
    let canonical = Unix.realpath root in
    if String.equal canonical root then Some (parts canonical) else None
  with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None

let in_roots roots target =
  List.exists (fun root -> match canonical_root root with
    | Some root -> below root target
    | None -> false) roots

let rec relative root path = match root, path with
  | [], rest -> Some rest
  | parent :: parents, child :: children when String.equal parent child -> relative parents children
  | _ :: _, _ -> None

let current_generated_read ~brain ~conversation target =
  match canonical_root brain with
  | None -> false
  | Some root ->
    (match relative root target with
     | Some [owner; ".system_generated"; "steps"; step; "output.txt"] ->
       String.equal owner conversation && step <> ""
       && String.for_all (function '0' .. '9' -> true | _ -> false) step
     | Some [owner; ".system_generated"; "logs"; ("transcript.jsonl" | "transcript_full.jsonl")] ->
       String.equal owner conversation
     | Some _ | None -> false)

let arguments () =
  let cwd = ref None and brain = ref None and read = ref [] and deny = ref [] in
  let rec parse = function
    | [] -> ()
    | "--cwd" :: value :: rest when !cwd = None -> cwd := Some value; parse rest
    | "--brain" :: value :: rest when !brain = None -> brain := Some value; parse rest
    | "--read-root" :: value :: rest -> read := value :: !read; parse rest
    | "--deny-root" :: value :: rest -> deny := value :: !deny; parse rest
    | _ :: _ -> raise Invalid_input in
  parse (List.tl (Array.to_list Sys.argv));
  match !cwd, !brain with
  | Some cwd, Some brain when not (Filename.is_relative cwd || Filename.is_relative brain) ->
    cwd, brain, !read, !deny
  | Some _, Some _ | None, _ | _, None -> raise Invalid_input

let decide () =
  let cwd, brain, read, deny = arguments () in
  let event : Yojson.Safe.t = Yojson.Safe.from_string (In_channel.input_all stdin) in
  let call = field "toolCall" event in
  match string (field "name" call) with
  | "read_file" ->
    let path = string (field "Path" (field "args" call)) in
    let path = if Filename.is_relative path then Filename.concat cwd path else path in
    let target = Unix.realpath path |> parts in
    if in_roots deny target then false
    else in_roots read target
      || current_generated_read ~brain ~conversation:(string (field "conversationId" event)) target
  | _ -> true

let () =
  let allowed =
    try decide () with
    | Invalid_input | Yojson.Json_error _ | Sys_error _ | Unix.Unix_error _
    | Invalid_argument _ -> false in
  let decision, reason = if allowed then "allow", "Defer to native permissions"
    else "deny", "Native read is outside the permitted files or could not be resolved. Use an available MASC tool for this operation." in
  Yojson.Safe.to_channel stdout (`Assoc ["decision", `String decision; "reason", `String reason]);
  output_char stdout '\n';
  flush stdout
