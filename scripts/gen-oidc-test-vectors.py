#!/usr/bin/env python3
"""Print test/oidc_id_token_vectors.ml: JWKS documents and signed ID tokens.

usage: python3 scripts/gen-oidc-test-vectors.py > test/oidc_id_token_vectors.ml

Makes four throwaway RSA keys and one EC key with openssl, signs tokens with
them, and prints OCaml string bindings. The private keys live in a temporary
directory that is deleted at the end; only public JWKS entries and signed
tokens are printed. The third RSA key is never listed in a JWKS: it stands for
an attacker. The fourth has a 2047-bit modulus, one bit under the limit the
tests expect. Every run makes new keys, so regenerate the whole file.

Before printing, each token is checked by a verifier written in this file
(RSA PKCS#1 v1.5 with SHA-256 or SHA-384, and HMAC-SHA-256). It shares no code
with openssl or with the library under test. The run fails when a token
verifies under a different key or hash than EXPECTED_VERIFIES says, so a claim
in the tests such as "signed by another listed key" stays true.
"""

import base64
import hashlib
import hmac
import json
import shutil
import subprocess
import sys
import tempfile

ISSUER = "https://accounts.google.com"
AUDIENCE = "test-client.apps.example"
FAR_FUTURE = 4102444800  # 2100-01-01T00:00:00Z
LONG_PAST = 1700000000  # 2023-11-14T22:13:20Z
ISSUED_AT = 1793000000
NOW = 1793145600  # 2026-10-28T00:00:00Z, the instant the tests treat as now
KEY_1 = "test-key-1"
KEY_2 = "test-key-2"
OCT_KEY = "oct-key"
PUBLIC_PEM_SECRET = "public-key-pem"
SHORT_KEY = "short-key"
RSA_BITS = "2048"
RSA_BITS_ONE_SHORT = "2047"
REPEATED_ALG = '"alg":"none"'  # a second alg member, after the RS256 one
REPEATED_EXP = f'"exp":{LONG_PAST}'  # a second exp member, in the past
NOT_JSON = b"this is not json"
NOT_AN_OBJECT = b"[1,2,3]"
EC_COORDINATE_BYTES = 32  # P-256; the point (0, 0) is not on the curve
TRUNCATED_SIGNATURE_CHARS = 100  # a multiple of 4, so the text still decodes
EXTRA_SIGNATURE_CHARS = "AAAA"
URL_SAFE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
RSA_SIGNATURE_BYTES = 256  # a 2048-bit key
PADDING_BITS_MASK = 0x0F  # 256 bytes end in a group of one byte: 4 unused bits

DIGEST_INFO_PREFIX = {
    "sha256": bytes.fromhex("3031300d060960864801650304020105000420"),
    "sha384": bytes.fromhex("3041300d060960864801650304020205000430"),
}

# Which (hash, key) pairs verify each token, found by the verifier below.
# "embedded" is the key a token's own header carries.
EXPECTED_VERIFIES: dict[str, set[str]] = {
    "token_valid_key_1": {"sha256@test-key-1"},
    "token_valid_key_2": {"sha256@test-key-2"},
    "token_expired": {"sha256@test-key-1"},
    "token_expires_at_now": {"sha256@test-key-1"},
    "token_expires_one_second_after_now": {"sha256@test-key-1"},
    "token_without_exp": {"sha256@test-key-1"},
    "token_exp_as_string": {"sha256@test-key-1"},
    "token_exp_as_float": {"sha256@test-key-1"},
    "token_payload_not_an_object": {"sha256@test-key-1"},
    "token_tampered": set(),
    "token_signed_by_the_other_key": {"sha256@test-key-2"},
    "token_signed_with_sha384": {"sha384@test-key-1"},
    "token_embedded_jwk_signed_by_attacker": {"sha256@embedded"},
    "token_embedded_ec_jwk_off_the_curve": {"sha256@test-key-1"},
    # Spellings that decode to the same bytes but are not the canonical text.
    # A strict verifier finds nothing valid in them.
    "token_signature_with_padding": set(),
    "token_signature_with_nonzero_padding_bits": set(),
    "token_payload_with_dangling_char": set(),
    "token_signature_not_base64url": set(),
    "token_zero_signature": set(),
    "token_signature_above_modulus": set(),
    "token_empty_signature": set(),
    "token_truncated_signature": set(),
    "token_signature_with_extra_bytes": set(),
    "token_alg_none": set(),
    "token_with_critical_header": {"sha256@test-key-1"},
    "token_hs256_with_public_key_as_secret": {"hmac-sha256@public-key-pem"},
    "token_rs256_header_for_oct_key": {"hmac-sha256@oct-key"},
    "token_rs256_header_for_ec_key": {"sha256@test-key-1"},
    "token_unknown_kid": {"sha256@test-key-1"},
    "token_without_kid": {"sha256@test-key-1"},
    "token_two_segments": set(),
    "token_flattened_json": set(),
    "token_payload_not_json": {"sha256@test-key-1"},
    "token_header_not_json": {"sha256@test-key-1"},
    "token_unknown_enc": {"sha256@test-key-1"},
    "token_alg_not_a_string": {"sha256@test-key-1"},
    # Signed correctly; the JSON repeats a member name, which a strict parser refuses.
    "token_header_repeats_alg": {"sha256@test-key-1"},
    "token_payload_repeats_exp": {"sha256@test-key-1"},
    # The only token the 2047-bit key signed.
    "token_signed_by_2047_bit_key": {"sha256@short-key"},
}


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64u_decode(text: str) -> bytes:
    """Decode only the canonical spelling (RFC 7515 section 2), unlike many decoders."""
    data = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    if b64u(data) != text:
        raise ValueError("not the canonical unpadded base64url spelling")
    return data


def run(*args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(list(args), input=stdin, capture_output=True, check=True).stdout


def rsa_key(directory: str, name: str, bits: str = RSA_BITS) -> str:
    path = f"{directory}/{name}.pem"
    run("openssl", "genrsa", "-out", path, bits)
    return path


def rsa_jwk(path: str, kid: str) -> dict:
    modulus_line = run("openssl", "rsa", "-in", path, "-noout", "-modulus").decode().strip()
    modulus = bytes.fromhex(modulus_line.split("=", 1)[1])
    return {"kty": "RSA", "kid": kid, "alg": "RS256", "use": "sig", "n": b64u(modulus), "e": "AQAB"}


def ec_jwk(directory: str, kid: str) -> dict:
    path = f"{directory}/ec.pem"
    run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", path)
    der = run("openssl", "ec", "-in", path, "-pubout", "-outform", "DER")
    point = der[-64:]
    return {"kty": "EC", "crv": "P-256", "kid": kid, "x": b64u(point[:32]), "y": b64u(point[32:])}


def without(jwk: dict, *names: str) -> dict:
    return {key: value for key, value in jwk.items() if key not in names}


def compact_json(value: object) -> str:
    return json.dumps(value, separators=(",", ":"))


def with_repeated_member(value: dict, member: str) -> str:
    """Compact JSON of an object plus one more member, given as JSON text, that repeats a name."""
    return compact_json(value)[:-1] + "," + member + "}"


def encode_part(value: dict) -> str:
    return b64u(compact_json(value).encode())


def claims(**overrides) -> dict:
    base = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": "user-1",
        "nonce": "nonce-1",
        "iat": ISSUED_AT,
        "exp": FAR_FUTURE,
    }
    base.update(overrides)
    return {key: value for key, value in base.items() if value is not None}


def header(alg: str = "RS256", kid: str | None = KEY_1, **extra) -> dict:
    value: dict = {"alg": alg, "typ": "JWT"}
    if kid is not None:
        value["kid"] = kid
    value.update(extra)
    return value


def signature_over(path: str, signing_input: str, digest: str = "sha256") -> str:
    raw = run("openssl", "dgst", f"-{digest}", "-sign", path, "-binary", stdin=signing_input.encode())
    return b64u(raw)


def sign_parts(path: str, header_part: str, payload_part: str, digest: str = "sha256") -> str:
    signing_input = f"{header_part}.{payload_part}"
    return f"{signing_input}.{signature_over(path, signing_input, digest)}"


def rs256(path: str, head: dict, payload: dict, digest: str = "sha256") -> str:
    return sign_parts(path, encode_part(head), encode_part(payload), digest)


def hs256(secret: bytes, head: dict, payload: dict) -> str:
    signing_input = f"{encode_part(head)}.{encode_part(payload)}"
    signature = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64u(signature)}"


def jwks(*keys: dict) -> str:
    return compact_json({"keys": list(keys)})


def with_nonzero_padding_bits(segment: str) -> str:
    """The same bytes, spelled with a set bit in the unused tail of the last character."""
    index = URL_SAFE_ALPHABET.index(segment[-1])
    if index & PADDING_BITS_MASK:
        raise SystemExit("the signature does not end in zero padding bits")
    return segment[:-1] + URL_SAFE_ALPHABET[index | 1]


def claims_in_whole_groups() -> dict:
    """Claims whose JSON is a whole number of 3-byte groups, so its base64url text has no tail."""
    note = ""
    while len(compact_json(claims(note=note)).encode()) % 3:
        note += "x"
    return claims(note=note)


def rsa_verifies(jwk: dict, signing_input: str, signature: bytes, digest: str) -> bool:
    modulus = int.from_bytes(b64u_decode(jwk["n"]), "big")
    exponent = int.from_bytes(b64u_decode(jwk["e"]), "big")
    size = (modulus.bit_length() + 7) // 8
    if len(signature) != size:
        return False
    encoded = pow(int.from_bytes(signature, "big"), exponent, modulus).to_bytes(size, "big")
    tail = DIGEST_INFO_PREFIX[digest] + hashlib.new(digest, signing_input.encode()).digest()
    expected = b"\x00\x01" + b"\xff" * (size - len(tail) - 3) + b"\x00" + tail
    return encoded == expected


def verifying_pairs(
    token: str, rsa_keys: dict[str, dict], hmac_secrets: dict[str, bytes]
) -> set[str]:
    parts = token.split(".")
    if len(parts) != 3:
        return set()
    signing_input = f"{parts[0]}.{parts[1]}"
    try:
        raw_header = b64u_decode(parts[0])
        b64u_decode(parts[1])
        signature = b64u_decode(parts[2])
    except ValueError:
        return set()
    candidates = dict(rsa_keys)
    try:
        head = json.loads(raw_header)
    except ValueError:
        head = None
    embedded = head.get("jwk") if isinstance(head, dict) else None
    if isinstance(embedded, dict) and "n" in embedded and "e" in embedded:
        candidates["embedded"] = embedded
    found = {
        f"{digest}@{kid}"
        for kid, jwk in candidates.items()
        for digest in DIGEST_INFO_PREFIX
        if rsa_verifies(jwk, signing_input, signature, digest)
    }
    for name, secret in hmac_secrets.items():
        if signature == hmac.new(secret, signing_input.encode(), hashlib.sha256).digest():
            found.add(f"hmac-sha256@{name}")
    return found


def ocaml_literal(name: str, text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'let {name} =\n  "{escaped}"\n'


def check_expectations(
    tokens: dict[str, str], rsa_keys: dict[str, dict], hmac_secrets: dict[str, bytes]
) -> None:
    missing = sorted(set(tokens) ^ set(EXPECTED_VERIFIES))
    if missing:
        sys.exit(f"EXPECTED_VERIFIES and the tokens differ on: {', '.join(missing)}")
    wrong = [
        f"{name}: expected {sorted(EXPECTED_VERIFIES[name])}, got {sorted(found)}"
        for name, token in tokens.items()
        if (found := verifying_pairs(token, rsa_keys, hmac_secrets)) != EXPECTED_VERIFIES[name]
    ]
    if wrong:
        sys.exit("a token verifies under another key or hash than expected:\n" + "\n".join(wrong))


def main() -> None:
    directory = tempfile.mkdtemp(prefix="jwt-vectors-")
    try:
        key1 = rsa_key(directory, "k1")
        key2 = rsa_key(directory, "k2")
        attacker = rsa_key(directory, "attacker")
        short = rsa_key(directory, "short", RSA_BITS_ONE_SHORT)
        jwk1 = rsa_jwk(key1, KEY_1)
        jwk2 = rsa_jwk(key2, KEY_2)
        attacker_jwk = rsa_jwk(attacker, KEY_1)
        short_jwk = rsa_jwk(short, KEY_1)
        ec = ec_jwk(directory, "ec-key")
        off_curve = {
            "kty": "EC",
            "crv": "P-256",
            "kid": "off-curve",
            "x": b64u(bytes(EC_COORDINATE_BYTES)),
            "y": b64u(bytes(EC_COORDINATE_BYTES)),
        }
        oct_secret = b"an-oct-key-that-must-never-verify-an-rs256-token!!"
        oct_jwk = {"kty": "oct", "kid": OCT_KEY, "alg": "HS256", "k": b64u(oct_secret)}
        public_pem_1 = run("openssl", "rsa", "-in", key1, "-pubout")

        valid = rs256(key1, header(), claims())
        header_part, payload_part, signature_part = valid.split(".")
        tampered = ".".join([header_part, encode_part(claims(sub="user-2")), signature_part])
        flattened_json = compact_json(
            {"protected": header_part, "payload": payload_part, "signature": signature_part}
        )
        truncated = signature_part[:TRUNCATED_SIGNATURE_CHARS]
        group_header, group_payload, group_signature = rs256(
            key1, header(), claims_in_whole_groups()
        ).split(".")
        all_zeros = b64u(bytes(RSA_SIGNATURE_BYTES))
        all_ones = b64u(b"\xff" * RSA_SIGNATURE_BYTES)

        keysets = {
            "jwks_both": jwks(jwk1, jwk2),
            "jwks_with_other_kinds": jwks(jwk1, ec, oct_jwk),
            "jwks_key_with_use_only": jwks(without(jwk1, "alg")),
            "jwks_key_with_alg_only": jwks(without(jwk1, "use")),
            "jwks_key_without_alg_and_use": jwks(without(jwk1, "alg", "use")),
            "jwks_key_for_encryption": jwks({**without(jwk1, "alg"), "use": "enc"}),
            "jwks_key_declared_rs256_for_encryption": jwks({**jwk1, "use": "enc"}),
            "jwks_key_declared_rs256_with_another_use": jwks({**jwk1, "use": "other"}),
            "jwks_key_declared_rs384": jwks({**jwk1, "alg": "RS384"}),
            "jwks_with_an_ec_key_off_the_curve": jwks(jwk1, off_curve),
            "jwks_key_2047_bits": jwks(short_jwk),
        }
        tokens = {
            "token_valid_key_1": valid,
            "token_valid_key_2": rs256(key2, header(kid=KEY_2), claims(sub="user-2")),
            "token_expired": rs256(key1, header(), claims(exp=LONG_PAST)),
            "token_expires_at_now": rs256(key1, header(), claims(exp=NOW)),
            "token_expires_one_second_after_now": rs256(key1, header(), claims(exp=NOW + 1)),
            "token_without_exp": rs256(key1, header(), claims(exp=None)),
            "token_exp_as_string": rs256(key1, header(), claims(exp=str(FAR_FUTURE))),
            "token_exp_as_float": rs256(key1, header(), claims(exp=float(FAR_FUTURE) + 0.5)),
            "token_payload_not_an_object": sign_parts(key1, header_part, b64u(NOT_AN_OBJECT)),
            "token_tampered": tampered,
            "token_signed_by_the_other_key": rs256(key2, header(kid=KEY_1), claims()),
            "token_signed_with_sha384": rs256(key1, header(), claims(), digest="sha384"),
            "token_embedded_jwk_signed_by_attacker": rs256(
                attacker, header(jwk=attacker_jwk), claims(sub="attacker")
            ),
            "token_embedded_ec_jwk_off_the_curve": rs256(
                key1, header(jwk=off_curve), claims()
            ),
            "token_signature_with_padding": f"{header_part}.{payload_part}.{signature_part}=",
            "token_signature_with_nonzero_padding_bits": (
                f"{header_part}.{payload_part}.{with_nonzero_padding_bits(signature_part)}"
            ),
            "token_payload_with_dangling_char": (
                f"{group_header}.{group_payload}A.{group_signature}"
            ),
            "token_signature_not_base64url": f"{header_part}.{payload_part}.!!!",
            "token_zero_signature": f"{header_part}.{payload_part}.{all_zeros}",
            "token_signature_above_modulus": f"{header_part}.{payload_part}.{all_ones}",
            "token_empty_signature": f"{header_part}.{payload_part}.",
            "token_truncated_signature": f"{header_part}.{payload_part}.{truncated}",
            "token_signature_with_extra_bytes": (
                f"{header_part}.{payload_part}.{signature_part}{EXTRA_SIGNATURE_CHARS}"
            ),
            "token_alg_none": f"{encode_part(header(alg='none'))}.{encode_part(claims())}.",
            "token_with_critical_header": rs256(key1, header(crit=["exp"]), claims()),
            "token_hs256_with_public_key_as_secret": hs256(
                public_pem_1, header(alg="HS256"), claims()
            ),
            "token_rs256_header_for_oct_key": hs256(oct_secret, header(kid=OCT_KEY), claims()),
            "token_rs256_header_for_ec_key": rs256(key1, header(kid="ec-key"), claims()),
            "token_unknown_kid": rs256(key1, header(kid="no-such-key"), claims()),
            "token_without_kid": rs256(key1, header(kid=None), claims()),
            "token_two_segments": f"{header_part}.{payload_part}",
            "token_flattened_json": flattened_json,
            "token_payload_not_json": sign_parts(key1, header_part, b64u(NOT_JSON)),
            "token_header_not_json": sign_parts(key1, b64u(NOT_JSON), payload_part),
            "token_unknown_enc": rs256(key1, header(enc="nope"), claims()),
            "token_alg_not_a_string": rs256(
                key1, {"alg": 5, "typ": "JWT", "kid": KEY_1}, claims()
            ),
            "token_header_repeats_alg": sign_parts(
                key1,
                b64u(with_repeated_member(header(), REPEATED_ALG).encode()),
                payload_part,
            ),
            "token_payload_repeats_exp": sign_parts(
                key1,
                header_part,
                b64u(with_repeated_member(claims(), REPEATED_EXP).encode()),
            ),
            "token_signed_by_2047_bit_key": rs256(short, header(), claims()),
        }
        check_expectations(
            tokens,
            {KEY_1: jwk1, KEY_2: jwk2, SHORT_KEY: short_jwk},
            {OCT_KEY: oct_secret, PUBLIC_PEM_SECRET: public_pem_1},
        )

        bindings = "\n".join(
            ocaml_literal(name, text) for name, text in {**keysets, **tokens}.items()
        )
        sys.stdout.write(
            "(* Generated by scripts/gen-oidc-test-vectors.py. Do not edit by hand.\n"
            "   Regenerate the whole file with:\n"
            "     python3 scripts/gen-oidc-test-vectors.py > test/oidc_id_token_vectors.ml\n"
            "   Every run makes new keys, so a single binding cannot be replaced.\n"
            "   The private keys that signed these tokens were thrown away. *)\n"
            "\n" + bindings
        )
    finally:
        shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    main()
