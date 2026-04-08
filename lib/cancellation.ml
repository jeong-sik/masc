(** Cancellation Tokens - MCP 2025-11-25 Spec Compliance

    Implements client-side cancellation support for long-running operations.
    Based on CancellationToken pattern.

    MCP Spec MAY: Support for client request cancellation
*)

(** Cancellation token state.
    [cancelled] uses [Atomic.t] for fiber-safe cross-fiber visibility in OCaml 5.
    [reason] is written before [cancelled] transitions to [true], ensuring fibers that
    observe cancelled=true also see the reason. [callbacks] may be modified via [on_cancel]
    at any time, but are only executed when [cancelled] transitions to [true]. *)
type token = {
  id: string;
  cancelled: bool Atomic.t;
  mutable reason: string option;
  mutable callbacks: (unit -> unit) list;
  created_at: float;
}

(** Token store - Thread-safe with Eio.Mutex protection *)
module TokenStore = struct
  let tokens : (string, token) Hashtbl.t = Hashtbl.create 64
  let lock : Eio.Mutex.t option ref = ref None
  let last_cleanup : float ref = ref 0.0
  let cleanup_interval = Env_config.InternalTimers.cancellation_cleanup_sec

  (** Initialize the token store with Eio mutex. Call once at server startup. *)
  let init () : unit =
    if !lock = None then lock := Some (Eio.Mutex.create ())

  (** Run operation with mutex protection *)
  let with_lock f =
    match !lock with
    | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())
    | None -> f ()  (* Fallback for non-Eio contexts or before init *)

  (** Internal cleanup - removes tokens older than max_age *)
  let cleanup_internal ~(max_age : float) : int =
    let now = Time_compat.now () in
    let old_tokens = Hashtbl.fold (fun id t acc ->
      if now -. t.created_at > max_age then id :: acc else acc
    ) tokens [] in
    List.iter (Hashtbl.remove tokens) old_tokens;
    List.length old_tokens

  (** Auto-cleanup on access if interval elapsed *)
  let maybe_auto_cleanup () =
    let now = Time_compat.now () in
    if now -. !last_cleanup > cleanup_interval then begin
      last_cleanup := now;
      let max_age = Env_config.Cancellation.token_max_age_seconds in
      let removed = cleanup_internal ~max_age in
      if removed > 0 then
        Log.Cancel.info "Auto-cleanup removed %d expired tokens" removed
    end

  (** Generate token ID *)
  let generate_id () : string =
    let bytes = Mirage_crypto_rng.generate 8 in
    let buf = Buffer.create 16 in
    for i = 0 to String.length bytes - 1 do
      Buffer.add_string buf (Printf.sprintf "%02x" (Char.code (String.get bytes i)))
    done;
    Printf.sprintf "cancel_%s" (Buffer.contents buf)

  (** Create new cancellation token *)
  let create () : token =
    with_lock (fun () ->
      maybe_auto_cleanup ();
      let token = {
        id = generate_id ();
        cancelled = Atomic.make false;
        reason = None;
        callbacks = [];
        created_at = Time_compat.now ();
      } in
      Hashtbl.add tokens token.id token;
      token
    )

  (** Get token by ID *)
  let get (id : string) : token option =
    with_lock (fun () -> Hashtbl.find_opt tokens id)

  (** Remove token *)
  let remove (id : string) : unit =
    with_lock (fun () -> Hashtbl.remove tokens id)

  (** List all tokens *)
  let list_all () : token list =
    with_lock (fun () -> Hashtbl.fold (fun _ t acc -> t :: acc) tokens [])

  (** Cleanup old tokens (older than max_age seconds) *)
  let cleanup ~(max_age : float) : int =
    with_lock (fun () ->
      last_cleanup := Time_compat.now ();
      cleanup_internal ~max_age
    )

  (** {2 ID-based convenience functions for testing} *)

  (** Create token with explicit ID (for testing/stress tests) *)
  let create_with_id (id : string) : unit =
    with_lock (fun () ->
      if not (Hashtbl.mem tokens id) then begin
        let token = {
          id;
          cancelled = Atomic.make false;
          reason = None;
          callbacks = [];
          created_at = Time_compat.now ();
        } in
        Hashtbl.add tokens id token
      end
    )

  (** Check if token is cancelled by ID *)
  let is_cancelled (id : string) : bool =
    with_lock (fun () ->
      match Hashtbl.find_opt tokens id with
      | Some t -> Atomic.get t.cancelled
      | None -> false
    )

  (** Cancel token by ID *)
  let cancel (id : string) : unit =
    with_lock (fun () ->
      match Hashtbl.find_opt tokens id with
      | Some t ->
        if not (Atomic.get t.cancelled) then begin
          Atomic.set t.cancelled true;
          List.iter (fun cb ->
            try cb () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Cancel.error "Callback failed: %s" (Printexc.to_string exn)
          ) t.callbacks
        end
      | None -> ()
    )
end

(** Check if token is cancelled *)
let is_cancelled (token : token) : bool =
  Atomic.get token.cancelled

(** Cancel a token - triggers all callbacks *)
let cancel ?(reason : string option) (token : token) : unit =
  (* Write reason first, then atomically transition cancelled to true.
     This ensures other fibers observing cancelled=true also see the reason. *)
  token.reason <- reason;
  if Atomic.compare_and_set token.cancelled false true then begin
    (* Execute callbacks in reverse order (LIFO) *)
    List.iter (fun cb ->
      try cb () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Cancel.error "Callback failed: %s" (Printexc.to_string exn)
    ) token.callbacks
  end

(** Register cancellation callback *)
let on_cancel (token : token) (callback : unit -> unit) : unit =
  token.callbacks <- callback :: token.callbacks

(** Cancel token by ID *)
let cancel_by_id ?(reason : string option) (id : string) : bool =
  match TokenStore.get id with
  | Some token ->
    cancel ?reason token;
    true
  | None -> false

(** Create a token linked to a task *)
let create_for_task ~(task_id : string) : token =
  let token = TokenStore.create () in
  (* Store task_id as metadata - we could extend token type later *)
  on_cancel token (fun () ->
    Log.Cancel.info "Task %s cancelled (token: %s)" task_id token.id
  );
  token

(** Token to JSON *)
let token_to_json (t : token) : Yojson.Safe.t =
  `Assoc [
    ("id", `String t.id);
    ("cancelled", `Bool (Atomic.get t.cancelled));
    ("reason", Json_util.string_opt_to_json t.reason);
    ("created_at", `Float t.created_at);
    ("callback_count", `Int (List.length t.callbacks));
  ]

(** MCP tool handler for cancellation *)
let handle_cancellation_tool (arguments : Yojson.Safe.t) : (bool * string) =
  let get_string key =
    match Yojson.Safe.Util.member key arguments with
    | `String s -> Some s
    | _ -> None
  in
  match get_string "action" with
  | Some "create" ->
    let token = TokenStore.create () in
    (true, Yojson.Safe.to_string (token_to_json token))

  | Some "cancel" ->
    (match get_string "token_id" with
     | Some id ->
       let reason = get_string "reason" in
       if cancel_by_id ?reason id then
         (true, Printf.sprintf "Token '%s' cancelled" id)
       else
         (false, Printf.sprintf "Token '%s' not found" id)
     | None -> (false, "token_id required"))

  | Some "check" ->
    (match get_string "token_id" with
     | Some id ->
       (match TokenStore.get id with
        | Some token -> (true, Yojson.Safe.to_string (token_to_json token))
        | None -> (false, Printf.sprintf "Token '%s' not found" id))
     | None -> (false, "token_id required"))

  | Some "list" ->
    let tokens = TokenStore.list_all () in
    let json = `Assoc [
      ("count", `Int (List.length tokens));
      ("tokens", `List (List.map token_to_json tokens));
    ] in
    (true, Yojson.Safe.to_string json)

  | Some "cleanup" ->
    let removed = TokenStore.cleanup ~max_age:Env_config.Cancellation.token_max_age_seconds in
    (true, Printf.sprintf "Cleaned up %d old tokens" removed)

  | Some other -> (false, Printf.sprintf "Unknown action: %s" other)
  | None -> (false, "action required: create, cancel, check, list, cleanup")
