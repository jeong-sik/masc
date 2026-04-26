(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    @since 2.145.0 *)

let sanitize_name name = Coord_utils_backend_setup.sanitize_namespace_segment name

let chat_dir base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "keeper_chat"
;;

let chat_path ~base_dir ~keeper_name =
  Filename.concat (chat_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")
;;

let ensure_dir_once ~base_dir = ignore (Keeper_fs.ensure_dir (chat_dir base_dir))

let encode_line ~role ~content ~ts : string =
  Yojson.Safe.to_string
    (`Assoc [ "role", `String role; "content", `String content; "ts", `Float ts ])
;;

let append_pair
      ~base_dir
      ~keeper_name
      ~(user_content : string)
      ~(assistant_content : string)
  =
  try
    ensure_dir_once ~base_dir;
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let user_line = encode_line ~role:"user" ~content:user_content ~ts in
    let asst_line = encode_line ~role:"assistant" ~content:assistant_content ~ts in
    Fs_compat.append_file path (user_line ^ "\n" ^ asst_line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name)
      (Printexc.to_string exn)
;;

type chat_message =
  { role : string
  ; content : string
  ; ts : float option
  }

let parse_line (line : string) : chat_message option =
  try
    let json = Yojson.Safe.from_string line in
    let open Yojson.Safe.Util in
    let role = member "role" json |> to_string_option |> Option.value ~default:"" in
    let content = member "content" json |> to_string_option |> Option.value ~default:"" in
    let ts =
      try Some (member "ts" json |> to_float) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> None
    in
    if role = "" || content = "" then None else Some { role; content; ts }
  with
  | Yojson.Json_error _ -> None
;;

let max_history = 100

let load ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  try
    let content = Fs_compat.load_file path in
    let lines = String.split_on_char '\n' content in
    (* Single pass: keep a running window of last max_history entries *)
    let q = Queue.create () in
    List.iter
      (fun line ->
         let trimmed = String.trim line in
         if trimmed <> ""
         then (
           match parse_line trimmed with
           | Some msg ->
             Queue.push msg q;
             if Queue.length q > max_history then ignore (Queue.pop q)
           | None -> ()))
      lines;
    Queue.fold (fun acc msg -> msg :: acc) [] q |> List.rev
  with
  | Sys_error _ -> []
  | exn ->
    Log.Keeper.warn
      "keeper_chat_store: load failed for %s: %s"
      (sanitize_name keeper_name)
      (Printexc.to_string exn);
    []
;;

let to_json_array (messages : chat_message list) : Yojson.Safe.t =
  `List
    (List.map
       (fun m ->
          `Assoc
            ([ "role", `String m.role; "content", `String m.content ]
             @
             match m.ts with
             | Some t -> [ "ts", `Float t ]
             | None -> []))
       messages)
;;
