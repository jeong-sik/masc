(** Minimal abstract secret holder.

    [t] is kept abstract (but coercible to [string] via the private type in
    the interface) so that API keys and tokens cannot be accidentally
    interpolated into logs or JSON.  The only intentional escape hatches are
    {!header_value} for HTTP header construction and the coercion in tests.

    @since 0.207.0 *)

type t = string
type identity = Identity of string

module Identity_fingerprint = struct
  type t = Identity_fingerprint of string

  let width = 8

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_string value =
    if String.length value <> width
    then
      Error
        (Printf.sprintf
           "secret identity fingerprint must contain exactly %d characters"
           width)
    else if not (String.for_all is_lower_hex value)
    then Error "secret identity fingerprint must contain lowercase hexadecimal characters"
    else Ok (Identity_fingerprint value)
  ;;

  let of_digest digest = Identity_fingerprint (String.sub digest 0 width)
  let of_identity (Identity digest) = of_digest digest
  let to_string (Identity_fingerprint value) = value

  let equal (Identity_fingerprint left) (Identity_fingerprint right) =
    String.equal left right
  ;;
end

let of_string s = s

let of_env ?(getenv = Cli_common_env.default_getenv) var =
  match Cli_common_env.get ~getenv var with
  | Some s -> Some (of_string s)
  | None -> None
;;

let empty = ""
let is_empty s = String.trim s = ""
let header_value s = s
let length = String.length
let digest s = Digestif.SHA256.(to_hex (digest_string s))
let identity s = if is_empty s then None else Some (Identity (digest s))
let equal_identity (Identity left) (Identity right) = String.equal left right
let hash_identity (Identity digest) = Hashtbl.hash digest

let fingerprint s =
  s |> digest |> Identity_fingerprint.of_digest |> Identity_fingerprint.to_string
;;

let%test "fingerprint is stable" =
  fingerprint (of_string "my-secret-key") = fingerprint (of_string "my-secret-key")
;;

let%test "fingerprint differs for different secrets" =
  fingerprint (of_string "a") <> fingerprint (of_string "b")
;;

let%test "empty secret is empty" = is_empty empty
let%test "empty secret has no identity" = Option.is_none (identity empty)

let%test "secret identity is stable and opaque" =
  match identity (of_string "my-secret-key"), identity (of_string "my-secret-key") with
  | Some left, Some right ->
    let left_fingerprint = Identity_fingerprint.of_identity left in
    equal_identity left right
    && hash_identity left = hash_identity right
    && Identity_fingerprint.equal
         left_fingerprint
         (Identity_fingerprint.of_identity right)
    && String.equal
         (Identity_fingerprint.to_string left_fingerprint)
         (fingerprint (of_string "my-secret-key"))
  | None, _ | _, None -> false
;;

let%test "secret of string round-trips through header_value" =
  header_value (of_string "k") = "k"
;;

let%test "secret of_env honors injected env boundary" =
  let getenv name = if String.equal name "OAS_TEST_SECRET" then Some "  k  " else None in
  match of_env ~getenv "OAS_TEST_SECRET" with
  | Some secret -> header_value secret = "k"
  | None -> false
;;

let%test "secret of_env treats empty env value as absent" =
  let getenv name = if String.equal name "OAS_TEST_SECRET" then Some "   " else None in
  of_env ~getenv "OAS_TEST_SECRET" = None
;;
