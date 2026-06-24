(** Destructive operations policy — typed TOML-backed catalogue. *)

type destructive_class = Shell_safety_types.destructive_class =
  | Recursive_delete
  | Sql_destructive
  | Forced_git_mutation
  | Privilege_escalation
  | Filesystem_format
  | Device_write
  | Process_signal
  | System_control

type destructive_pattern = Shell_safety_types.destructive_pattern = {
  class_ : destructive_class;
  pattern : string;
  description : string;
}

type t = {
  enabled : bool;
  patterns : destructive_pattern list;
}

type load_error = {
  path : string;
  message : string;
}
[@@deriving show]

let enabled t = t.enabled
let patterns t = t.patterns

let of_patterns ~enabled patterns = { enabled; patterns }

(* ------------------------------------------------------------------ *)
(* Error helpers                                                      *)
(* ------------------------------------------------------------------ *)

let error path message = { path; message }
let single_error path message = Error [ error path message ]

let partition_results results =
  let oks, errs =
    List.partition_map
      (function Ok x -> Either.Left x | Error e -> Either.Right e)
      results
  in
  if errs <> [] then Error (List.concat errs) else Ok oks
;;

(* ------------------------------------------------------------------ *)
(* Class parsing                                                      *)
(* ------------------------------------------------------------------ *)

let class_of_string = function
  | "recursive_delete" -> Ok Recursive_delete
  | "sql_destructive" -> Ok Sql_destructive
  | "forced_git_mutation" -> Ok Forced_git_mutation
  | "privilege_escalation" -> Ok Privilege_escalation
  | "filesystem_format" -> Ok Filesystem_format
  | "device_write" -> Ok Device_write
  | "process_signal" -> Ok Process_signal
  | "system_control" -> Ok System_control
  | other -> Error (Printf.sprintf "unknown destructive class %S" other)
;;

(* ------------------------------------------------------------------ *)
(* Pattern parsing                                                    *)
(* ------------------------------------------------------------------ *)

let parse_pattern ~path (tbl : Otoml.t) : (destructive_pattern, load_error list) result =
  let require_string ~key ~msg =
    match Otoml.find_opt tbl Otoml.get_string [ key ] with
    | Some value when String.trim value <> "" -> Ok value
    | Some _ -> single_error (path ^ "." ^ key) (msg ^ ": empty string")
    | None -> single_error (path ^ "." ^ key) (msg ^ ": missing")
  in
  match require_string ~key:"class" ~msg:"pattern class" with
  | Error errs -> Error errs
  | Ok class_str ->
    (match class_of_string class_str with
     | Error msg -> single_error (path ^ ".class") msg
     | Ok class_ ->
       match require_string ~key:"pattern" ~msg:"pattern substring" with
       | Error errs -> Error errs
       | Ok pattern ->
         match require_string ~key:"description" ~msg:"pattern description" with
         | Error errs -> Error errs
         | Ok description -> Ok { class_; pattern; description })
;;

(* ------------------------------------------------------------------ *)
(* TOML loader                                                        *)
(* ------------------------------------------------------------------ *)

let load_string (content : string) : (t, load_error list) result =
  let doc =
    match Otoml.Parser.from_string_result content with
    | Ok doc -> Ok doc
    | Error msg -> single_error "<toml>" (Printf.sprintf "TOML parse error: %s" msg)
  in
  Result.bind doc (fun doc ->
    let ops_tbl =
      Otoml.find_or ~default:(Otoml.TomlTable []) doc Fun.id [ "destructive_ops" ]
    in
    let enabled =
      Otoml.find_or ~default:true ops_tbl Otoml.get_boolean [ "enabled" ]
    in
    let pattern_tables =
      Otoml.find_or ~default:[] ops_tbl (Otoml.get_array Fun.id) [ "patterns" ]
    in
    if pattern_tables = [] then
      single_error "destructive_ops.patterns" "at least one pattern is required"
    else
      match
        partition_results
          (List.mapi
             (fun i tbl -> parse_pattern ~path:(Printf.sprintf "destructive_ops.patterns[%d]" i) tbl)
             pattern_tables)
      with
      | Error errs -> Error errs
      | Ok patterns -> Ok { enabled; patterns })
;;

let load_file (path : string) : (t, load_error list) result =
  match
    Safe_ops.protect ~default:None (fun () -> Some (Fs_compat.load_file path))
  with
  | None -> Error [ error (path ^ ":io") "file not found or unreadable" ]
  | Some content ->
    Result.map_error
      (List.map (fun e -> { e with path = path ^ ":" ^ e.path }))
      (load_string content)
;;

(* ------------------------------------------------------------------ *)
(* Embedded default                                                   *)
(* ------------------------------------------------------------------ *)

let default : t =
  match Embedded_config.read "destructive_ops.toml" with
  | None -> failwith "Destructive_ops_policy.default: destructive_ops.toml not embedded"
  | Some content ->
    (match load_string content with
     | Ok t -> t
     | Error errs ->
       let msg =
         String.concat "; "
           (List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs)
       in
       failwith ("Destructive_ops_policy.default: embedded config invalid: " ^ msg))
;;
