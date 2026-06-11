(** CLI argument parser implementation. *)

type spec =
  | Positional of string
  | Flag of string
  | Option of string
  | Positional_opt of string * string

type t = {
  positional : string list;
  named : (string, string) Hashtbl.t;
}

type error =
  | Unknown_flag of string
  | Missing_value of string
  | Missing_positional of string

let pp_error = function
  | Unknown_flag name -> Printf.sprintf "unknown flag: --%s" name
  | Missing_value name -> Printf.sprintf "option --%s requires a value" name
  | Missing_positional name -> Printf.sprintf "missing positional argument: %s" name

(** {1 Query helpers} *)

let get_flag t name =
  try
    let v = Hashtbl.find t.named name in
    v = "true"
  with Not_found -> false

let has_flag = get_flag

let positional_args t = t.positional

let get_option t name =
  try
    let v = Hashtbl.find t.named name in
    if v = "true" then None    (* it's a flag, not an option value *)
    else Some v
  with Not_found -> None

(** {1 Parse} *)

let parse specs argv =
  (* Build lookup maps *)
  let flags = Hashtbl.create 16 in
  let options = Hashtbl.create 16 in
  let positionals = Hashtbl.create 16 in
  let positional_opts = Hashtbl.create 16 in
  let positional_order = ref [] in
  List.iter (fun spec ->
    match spec with
    | Flag name -> Hashtbl.replace flags name true
    | Option name -> Hashtbl.replace options name true
    | Positional name ->
        Hashtbl.replace positionals name true;
        positional_order := !positional_order @ [name]
    | Positional_opt (name, default) ->
        Hashtbl.replace positional_opts name default;
        positional_order := !positional_order @ [name]
  ) specs;

  let named = Hashtbl.create 16 in
  let pos_args = ref [] in
  let len = Array.length argv in

  (* Pre-fill defaults *)
  Hashtbl.iter (fun name _ ->
    Hashtbl.replace named name "true") flags;
  Hashtbl.iter (fun name default ->
    Hashtbl.replace named name default) positional_opts;

  let i = ref 1 in
  let pos_idx = ref 0 in

  while !i < len do
    let token = argv.(!i) in
    if token = "--" then begin
      (* Everything after -- is positional *)
      incr i;
      while !i < len do
        pos_args := !pos_args @ [argv.(!i)];
        incr i
      done
    end else if String.length token >= 2 && String.sub token 0 2 = "--" then begin
      let name = String.sub token 2 (String.length token - 2) in
      if Hashtbl.mem flags name then begin
        Hashtbl.replace named name "true";
        incr i
      end else if Hashtbl.mem options name then begin
        incr i;
        if !i >= len then
          Error (Missing_value name)
        else begin
          Hashtbl.replace named name argv.(!i);
          incr i
        end
      end else begin
        (* Check if it looks like --key=value *)
        let eq_pos = try Some (String.index name '=') with Not_found -> None in
        match eq_pos with
        | Some pos ->
            let key = String.sub name 0 pos in
            let value = String.sub name (pos + 1) (String.length name - pos - 1) in
            if Hashtbl.mem options key then begin
              Hashtbl.replace named key value;
              incr i
            end else if Hashtbl.mem flags key then begin
              (* --flag=value doesn't make sense for bool flags;
                 treat the whole thing as unknown *)
              Error (Unknown_flag name)
            end else
              Error (Unknown_flag name)
        | None ->
            Error (Unknown_flag name)
      end
    end else begin
      (* Positional argument *)
      if !pos_idx < List.length !positional_order then begin
        let name = List.nth !positional_order !pos_idx in
        Hashtbl.replace named name token;
        incr pos_idx;
        incr i
      end else begin
        pos_args := !pos_args @ [token];
        incr i
      end
    end
  done;

  (* Check missing required positionals *)
  let missing = ref [] in
  Hashtbl.iter (fun name _ ->
    if not (Hashtbl.mem named name) then
      let has_default = Hashtbl.mem positional_opts name in
      if not has_default then
        missing := name :: !missing
  ) positionals;

  match !missing with
  | name :: _ -> Error (Missing_positional name)
  | [] ->
      let result = {
        positional = List.rev !pos_args;
        named;
      } in
      Ok result