(** Per-cascade inference parameters from cascade.json.

    Reads optional {name}_temperature and {name}_max_tokens fields from the
    same cascade.json used by OAS Cascade_config.  This allows keeper and
    other MASC modules to delegate inference parameter decisions to the
    cascade configuration instead of maintaining parallel env-var knobs.

    Resolution order:
    1. cascade.json "{name}_temperature" / "{name}_max_tokens"
    2. cascade.json "default_temperature" / "default_max_tokens"
    3. Caller-provided fallback

    @since v2.128.0 — #2408 Phase 3 keeper inference delegation *)

(** Inference parameters resolved from cascade config. *)
type t = {
  temperature : float option;
  max_tokens : int option;
}

let empty = { temperature = None; max_tokens = None }

(* ── JSON cache (mtime-based hot-reload) ────────────────────
   Uses own cache because OAS Cascade_config.load_json is not
   exposed in the public .mli (only load_profile is).
   TODO: Expose load_json in OAS .mli, then delegate here. *)

let json_cache : (string, float * Yojson.Safe.t) Hashtbl.t =
  Hashtbl.create 2

let load_json (path : string) : Yojson.Safe.t option =
  try
    let st = Unix.stat path in
    let mtime = st.Unix.st_mtime in
    match Hashtbl.find_opt json_cache path with
    | Some (cached_mtime, json) when Float.equal cached_mtime mtime ->
      Some json
    | _ ->
      let ic = open_in path in
      let content = Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
             let len = in_channel_length ic in
             let buf = Bytes.create len in
             really_input ic buf 0 len;
             Bytes.to_string buf)
      in
      let json = Yojson.Safe.from_string content in
      Hashtbl.replace json_cache path (mtime, json);
      Some json
  with
  | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _ | End_of_file -> None

(* ── Field extraction helpers ──────────────────────────── *)

let read_float_field (json : Yojson.Safe.t) (key : string) : float option =
  match Yojson.Safe.Util.member key json with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let read_int_field (json : Yojson.Safe.t) (key : string) : int option =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | _ -> None

(* ── Core extraction from a JSON value ─────────────────── *)

(** Extract inference parameters from a parsed JSON value for a named cascade.
    Exposed for testing without filesystem dependency. *)
let for_json ~(name : string) (json : Yojson.Safe.t) : t =
  let named_temp_key = name ^ "_temperature" in
  let named_tokens_key = name ^ "_max_tokens" in
  let default_temp_key = "default_temperature" in
  let default_tokens_key = "default_max_tokens" in
  let temperature =
    match read_float_field json named_temp_key with
    | Some _ as v -> v
    | None -> read_float_field json default_temp_key
  in
  let max_tokens =
    match read_int_field json named_tokens_key with
    | Some _ as v -> v
    | None -> read_int_field json default_tokens_key
  in
  { temperature; max_tokens }

(* ── Public API ────────────────────────────────────────── *)

(** Load inference parameters for a named cascade profile.

    Reads from cascade.json located via {!Oas_worker.default_config_path}.
    Keys follow the pattern: "{name}_temperature", "{name}_max_tokens".
    Falls back to "default_temperature" / "default_max_tokens" when the
    named key is absent. *)
let for_cascade ~(name : string) : t =
  match Oas_worker.default_config_path () with
  | None -> empty
  | Some path ->
    match load_json path with
    | None -> empty
    | Some json -> for_json ~name json

(** Resolve a temperature value: cascade config -> env-var fallback -> hardcoded default. *)
let resolve_temperature ~(cascade_name : string) ~(fallback : unit -> float) : float =
  match (for_cascade ~name:cascade_name).temperature with
  | Some t -> t
  | None -> fallback ()

(** Resolve a max_tokens value: cascade config -> env-var fallback -> hardcoded default. *)
let resolve_max_tokens ~(cascade_name : string) ~(fallback : unit -> int) : int =
  match (for_cascade ~name:cascade_name).max_tokens with
  | Some t -> t
  | None -> fallback ()
