(** Test is_safe_request_id path traversal guards. *)

let is_safe = Keeper_msg_async.For_testing.is_safe_request_id

(** Valid request IDs — should be safe *)
let%test "normal alphanumeric" = is_safe "abc123"
let%test "with hyphens" = is_safe "my-request-42"
let%test "with underscores" = is_safe "my_request_42"
let%test "single char alpha" = is_safe "a"
let%test "max length valid" =
  let s = String.init 128 (fun _ -> 'x') in
  is_safe s

(** Edge cases — request_id containing dots in valid patterns *)
let%test "dot in middle" = is_safe "req.123"
let%test "trailing dot" = is_safe "request."

(** Path traversal attempts — must be rejected *)
let%test _ "single dot rejected" = not (is_safe ".")
let%test _ "double dot rejected" = not (is_safe "..")
let%test _ "empty string rejected" = not (is_safe "")
let%test _ "over max length" =
  let s = String.init 129 (fun _ -> 'x') in
  not (is_safe s)
let%test _ "slash rejected" = not (is_safe "../etc/passwd")
let%test _ "dots with slash" = not (is_safe "../../config")
let%test _ "only dots multiple" = not (is_safe "...")
let%test _ "dots and slash combo" = not (is_safe "a/../b")

(** record_path integration — uses is_safe_request_id *)
let%test "record_path returns Some for safe id" =
  match Keeper_msg_async.For_testing.record_path ~base_path:"/tmp" ~request_id:"safe-42" with
  | Some _ -> true
  | None -> false

let%test "record_path returns None for path traversal" =
  match Keeper_msg_async.For_testing.record_path ~base_path:"/tmp" ~request_id:".." with
  | Some _ -> false
  | None -> true

let%test "record_path returns None for single dot" =
  match Keeper_msg_async.For_testing.record_path ~base_path:"/tmp" ~request_id:"." with
  | Some _ -> false
  | None -> true