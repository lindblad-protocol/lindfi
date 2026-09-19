"""
B5 — canonical FinancingOffer artifact: schema-first validation, RFC 8785 canonicalization and hashing.

Frozen by LINDFI_B5_TECHNICAL_INTEGRATION_SPEC_v0.2.md
SHA-256 4eea6395924b5dbd34ae0368f49936f7441b4b16a455a31fe544343773b67be4

    canonicalBytes = UTF8(RFC8785-JCS(validatedArtifact))
    offerHash      = SHA-256(canonicalBytes)
    offerIdHash    = keccak256(UTF8(canonical lowercase hyphenated UUID v4))

Scope note (B4/B5 separation, deliberate and frozen):
    B4 CollateralAssessment artifacts are hashed as SHA-256 of their existing PRETTY serialization
    (json.dumps with sort_keys=False). That convention is frozen and is NOT changed, migrated,
    recomputed or reinterpreted here. RFC8785-JCS is authoritative ONLY for B5 FinancingOffer
    artifacts. There is no protocol-global JCS assumption.

Validation happens BEFORE canonicalization: rfc8785 is a canonicalizer, not the schema authority.
An invalid artifact is rejected, never silently normalized.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any, Dict, Tuple

import rfc8785  # trailofbits/rfc8785.py 0.1.4 — pure Python, no runtime dependencies

SPEC_SHA256 = "4eea6395924b5dbd34ae0368f49936f7441b4b16a455a31fe544343773b67be4"
SCHEMA_VERSION = "1.0"

# ── rejection categories (stable identifiers, also used by the shared vector dataset) ──
R_NOT_OBJECT = "NOT_AN_OBJECT"
R_MISSING = "MISSING_FIELD"
R_UNKNOWN = "UNKNOWN_FIELD"
R_TYPE = "WRONG_TYPE"
R_SCHEMA_VERSION = "BAD_SCHEMA_VERSION"
R_UUID = "MALFORMED_UUID"
R_FLOAT = "FLOAT_NOT_PERMITTED"
R_DECSTR = "DECIMAL_STRING_REQUIRED"
R_BOUNDS = "INTEGER_OUT_OF_BOUNDS"
R_FORBIDDEN_OFFERHASH = "FORBIDDEN_OFFERHASH_FIELD"
R_FORBIDDEN_SIGNATURE = "FORBIDDEN_SIGNATURE_FIELD"
R_MUTABLE_STATUS = "MUTABLE_LIFECYCLE_STATE"
R_STATUS_AT_ISSUANCE = "BAD_STATUS_AT_ISSUANCE"
R_DEMO = "BAD_DEMO_AT_ISSUANCE"
R_DISCLOSURE = "BAD_DISCLOSURE"
R_HASH_ALGO = "BAD_RECORD_HASH_ALGORITHM"
R_CANON = "BAD_CANONICALIZATION"
R_HEX32 = "MALFORMED_HEX32"
R_ADDRESS = "MALFORMED_ADDRESS"
R_ASSET_DESCRIPTOR = "INVALID_ASSET_DESCRIPTOR"
R_ENUM = "INVALID_ENUM"
R_TIMESTAMPS = "INVALID_TIMESTAMPS"

MAX_SAFE_INTEGER = 2 ** 53 - 1
UUID_V4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
HEX32_RE = re.compile(r"^0x[0-9a-f]{64}$")
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
DECIMAL_STRING_RE = re.compile(r"^(0|[1-9][0-9]*)$")

# Fields that must never appear anywhere in the artifact (spec §7.1 rules 2 and 3).
FORBIDDEN_ANYWHERE = {
    "offerhash": R_FORBIDDEN_OFFERHASH,
    "lendersignature": R_FORBIDDEN_SIGNATURE,
    "signature": R_FORBIDDEN_SIGNATURE,
}
# Mutable lifecycle facts belong to the registry, never to the hashed artifact (spec §7.1 rule 1).
MUTABLE_STATUS_VALUES = {"ACCEPTED", "DECLINED", "WITHDRAWN", "EXPIRED"}

TOP_LEVEL_REQUIRED = [
    "schemaVersion", "offerId", "assetId", "lenderId", "assessmentReference", "recipient",
    "economics", "issuedAt", "expiresAt", "statusAtIssuance", "demoAtIssuance", "disclosure",
    "recordHashAlgorithm", "canonicalization", "notice",
]
TOP_LEVEL_OPTIONAL = ["conditions"]


class ArtifactValidationError(ValueError):
    """Raised when a FinancingOffer artifact is not valid under the frozen B5 schema."""

    def __init__(self, category: str, path: str, detail: str = "") -> None:
        self.category = category
        self.path = path
        super().__init__(f"{category} at {path}" + (f": {detail}" if detail else ""))


def _fail(category: str, path: str, detail: str = "") -> None:
    raise ArtifactValidationError(category, path, detail)


def _is_bool(v: Any) -> bool:
    return isinstance(v, bool)


def _is_int(v: Any) -> bool:
    # bool is a subclass of int in Python; a boolean is never an acceptable integer here.
    return isinstance(v, int) and not isinstance(v, bool)


def _check_no_floats_and_no_forbidden(node: Any, path: str) -> None:
    """Recursive scan: no float anywhere, no forbidden field anywhere, no mutable lifecycle value."""
    if isinstance(node, float):
        _fail(R_FLOAT, path, "floating point is never permitted in a FinancingOffer artifact")
    if isinstance(node, dict):
        for k, v in node.items():
            if not isinstance(k, str):
                _fail(R_TYPE, f"{path}.{k!r}", "object keys must be strings")
            cat = FORBIDDEN_ANYWHERE.get(k.lower())
            if cat:
                _fail(cat, f"{path}.{k}")
            if k == "status":
                _fail(R_MUTABLE_STATUS, f"{path}.status", "lifecycle state is a registry fact, not an artifact field")
            if isinstance(v, str) and k.lower().endswith("status") and v in MUTABLE_STATUS_VALUES:
                _fail(R_MUTABLE_STATUS, f"{path}.{k}", v)
            _check_no_floats_and_no_forbidden(v, f"{path}.{k}")
    elif isinstance(node, (list, tuple)):
        for i, v in enumerate(node):
            _check_no_floats_and_no_forbidden(v, f"{path}[{i}]")


def _bounded_int(node: Any, path: str, lo: int, hi: int) -> int:
    if not _is_int(node):
        _fail(R_TYPE, path, "bounded integer expected as a JSON integer")
    if node > MAX_SAFE_INTEGER:
        _fail(R_BOUNDS, path, "exceeds Number.MAX_SAFE_INTEGER; must be a decimal string if permitted")
    if not (lo <= node <= hi):
        _fail(R_BOUNDS, path, f"expected {lo}..{hi}, got {node}")
    return node


def _decimal_string(node: Any, path: str) -> int:
    """Large integers are decimal strings by frozen rule; the string is authoritative."""
    if not isinstance(node, str):
        _fail(R_DECSTR, path, "must be a decimal string, not a JSON number")
    if not DECIMAL_STRING_RE.match(node):
        _fail(R_DECSTR, path, "must match ^(0|[1-9][0-9]*)$ (no sign, no leading zeros, no exponent)")
    return int(node)


def _asset_descriptor(node: Any, path: str) -> None:
    if not isinstance(node, dict):
        _fail(R_TYPE, path, "object expected")
    kind = node.get("kind")
    if kind not in ("FIAT", "NATIVE", "ERC20"):
        _fail(R_ENUM, f"{path}.kind", str(kind))
    allowed = {"kind", "decimals", "code", "chainId", "token", "symbol"}
    unknown = sorted(set(node) - allowed)
    if unknown:
        _fail(R_UNKNOWN, path, ",".join(unknown))
    _bounded_int(node.get("decimals"), f"{path}.decimals", 0, 36)
    if kind == "FIAT":
        code = node.get("code")
        if not isinstance(code, str) or not re.fullmatch(r"[A-Z]{3}", code):
            _fail(R_ASSET_DESCRIPTOR, f"{path}.code", "FIAT requires a 3-letter uppercase code")
        if "chainId" in node or "token" in node:
            _fail(R_ASSET_DESCRIPTOR, path, "FIAT must not carry chainId or token")
    else:
        if "code" in node:
            _fail(R_ASSET_DESCRIPTOR, f"{path}.code", "only FIAT carries a currency code")
        _bounded_int(node.get("chainId"), f"{path}.chainId", 1, MAX_SAFE_INTEGER)
        if kind == "ERC20":
            tok = node.get("token")
            if not isinstance(tok, str) or not ADDRESS_RE.match(tok):
                _fail(R_ADDRESS, f"{path}.token")
        elif "token" in node:
            _fail(R_ASSET_DESCRIPTOR, f"{path}.token", "NATIVE must not carry a token address")
    if "symbol" in node and not isinstance(node["symbol"], str):
        _fail(R_TYPE, f"{path}.symbol", "display metadata must be a string (non-authoritative)")


def validate_artifact(artifact: Any) -> Dict[str, Any]:
    """Validate a logical FinancingOffer artifact against the frozen B5 schema. Returns it unchanged."""
    if not isinstance(artifact, dict):
        _fail(R_NOT_OBJECT, "$")

    # Global scans first: floats, forbidden fields and mutable lifecycle state anywhere in the tree.
    _check_no_floats_and_no_forbidden(artifact, "$")

    missing = [k for k in TOP_LEVEL_REQUIRED if k not in artifact]
    if missing:
        _fail(R_MISSING, "$", ",".join(missing))
    unknown = sorted(set(artifact) - set(TOP_LEVEL_REQUIRED) - set(TOP_LEVEL_OPTIONAL))
    if unknown:
        _fail(R_UNKNOWN, "$", ",".join(unknown))

    if artifact["schemaVersion"] != SCHEMA_VERSION:
        _fail(R_SCHEMA_VERSION, "$.schemaVersion", str(artifact["schemaVersion"]))
    if not isinstance(artifact["offerId"], str) or not UUID_V4_RE.match(artifact["offerId"]):
        _fail(R_UUID, "$.offerId", "canonical lowercase hyphenated UUID v4 required")
    if not isinstance(artifact["assetId"], str) or not artifact["assetId"]:
        _fail(R_TYPE, "$.assetId", "asset label or 0x-hash string expected")
    _bounded_int(artifact["lenderId"], "$.lenderId", 1, 2 ** 32 - 1)
    if not isinstance(artifact["recipient"], str) or not ADDRESS_RE.match(artifact["recipient"]):
        _fail(R_ADDRESS, "$.recipient")

    ar = artifact["assessmentReference"]
    if not isinstance(ar, dict):
        _fail(R_TYPE, "$.assessmentReference", "object expected")
    ar_required = {"assetIdHash", "assessmentIndex", "assessmentHash", "validUntil"}
    ar_unknown = sorted(set(ar) - ar_required - {"anchorIdHint"})
    if not ar_required <= set(ar):
        _fail(R_MISSING, "$.assessmentReference", ",".join(sorted(ar_required - set(ar))))
    if ar_unknown:
        _fail(R_UNKNOWN, "$.assessmentReference", ",".join(ar_unknown))
    for k in ("assetIdHash", "assessmentHash"):
        if not isinstance(ar[k], str) or not HEX32_RE.match(ar[k]):
            _fail(R_HEX32, f"$.assessmentReference.{k}", "0x + 64 lowercase hex required")
    _decimal_string(ar["assessmentIndex"], "$.assessmentReference.assessmentIndex")
    valid_until = _decimal_string(ar["validUntil"], "$.assessmentReference.validUntil")
    if "anchorIdHint" in ar:
        _decimal_string(ar["anchorIdHint"], "$.assessmentReference.anchorIdHint")

    ec = artifact["economics"]
    if not isinstance(ec, dict):
        _fail(R_TYPE, "$.economics", "object expected")
    ec_required = {"principalAmount", "denomination", "settlement", "rateType", "rateBps", "term"}
    if not ec_required <= set(ec):
        _fail(R_MISSING, "$.economics", ",".join(sorted(ec_required - set(ec))))
    ec_unknown = sorted(set(ec) - ec_required)
    if ec_unknown:
        _fail(R_UNKNOWN, "$.economics", ",".join(ec_unknown))
    principal = _decimal_string(ec["principalAmount"], "$.economics.principalAmount")
    if principal <= 0:
        _fail(R_BOUNDS, "$.economics.principalAmount", "must be greater than zero")
    _asset_descriptor(ec["denomination"], "$.economics.denomination")
    _asset_descriptor(ec["settlement"], "$.economics.settlement")
    if ec["rateType"] != "FIXED":
        _fail(R_ENUM, "$.economics.rateType", "B5 MVP freezes rateType = FIXED")
    _bounded_int(ec["rateBps"], "$.economics.rateBps", 0, 10_000)
    term = ec["term"]
    if not isinstance(term, dict) or set(term) != {"value", "unit"}:
        _fail(R_TYPE, "$.economics.term", "object with exactly value and unit")
    _bounded_int(term["value"], "$.economics.term.value", 1, MAX_SAFE_INTEGER)
    if term["unit"] not in ("DAYS", "MONTHS"):
        _fail(R_ENUM, "$.economics.term.unit", str(term["unit"]))

    if "conditions" in artifact:
        cond = artifact["conditions"]
        if not isinstance(cond, list) or not all(isinstance(x, str) for x in cond):
            _fail(R_TYPE, "$.conditions", "array of strings expected (hash-protected, not machine-enforced)")

    issued = _bounded_int(artifact["issuedAt"], "$.issuedAt", 1, MAX_SAFE_INTEGER)
    expires = _bounded_int(artifact["expiresAt"], "$.expiresAt", 1, MAX_SAFE_INTEGER)
    if expires <= issued:
        _fail(R_TIMESTAMPS, "$.expiresAt", "expiresAt must be strictly greater than issuedAt")
    if issued > valid_until:
        _fail(R_TIMESTAMPS, "$.issuedAt", "issuance cannot postdate the referenced assessment validity")

    if artifact["statusAtIssuance"] != "ISSUED":
        _fail(R_STATUS_AT_ISSUANCE, "$.statusAtIssuance", str(artifact["statusAtIssuance"]))
    if artifact["demoAtIssuance"] is not True:
        _fail(R_DEMO, "$.demoAtIssuance", "B5 MVP requires demoAtIssuance = true")
    if artifact["disclosure"] != "PUBLIC_DEMO":
        _fail(R_DISCLOSURE, "$.disclosure", str(artifact["disclosure"]))
    if artifact["recordHashAlgorithm"] != "SHA-256":
        _fail(R_HASH_ALGO, "$.recordHashAlgorithm", str(artifact["recordHashAlgorithm"]))
    if artifact["canonicalization"] != "RFC8785-JCS":
        _fail(R_CANON, "$.canonicalization", str(artifact["canonicalization"]))
    if not isinstance(artifact["notice"], str) or not artifact["notice"]:
        _fail(R_TYPE, "$.notice", "non-empty string expected")
    if not _is_bool(artifact["demoAtIssuance"]):
        _fail(R_TYPE, "$.demoAtIssuance", "boolean expected")

    return artifact


def canonical_bytes(artifact: Dict[str, Any]) -> bytes:
    """Validate, then canonicalize with RFC 8785. These are the exact bytes to publish and to hash."""
    validate_artifact(artifact)
    return rfc8785.dumps(artifact)


def sha256_hex(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def offer_hash(artifact: Dict[str, Any]) -> str:
    """offerHash = SHA-256(UTF8(JCS(validated artifact))). offerHash is never inside its own preimage."""
    return sha256_hex(canonical_bytes(artifact))


def _keccak256(data: bytes) -> bytes:
    """Keccak-256 (Ethereum flavour), pure Python, no dependency."""
    RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
          0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
          0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
          0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
          0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
          0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    R = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
    M = (1 << 64) - 1
    rate = 136

    def rol(x: int, n: int) -> int:
        return ((x << n) | (x >> (64 - n))) & M

    st = [[0] * 5 for _ in range(5)]
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] |= 0x80
    for off in range(0, len(padded), rate):
        blk = padded[off:off + rate]
        for i in range(rate // 8):
            st[i % 5][i // 5] ^= int.from_bytes(blk[i * 8:(i + 1) * 8], "little")
        for rnd in range(24):
            Cc = [st[x][0] ^ st[x][1] ^ st[x][2] ^ st[x][3] ^ st[x][4] for x in range(5)]
            Dd = [Cc[(x - 1) % 5] ^ rol(Cc[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    st[x][y] ^= Dd[x]
            B = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = rol(st[x][y], R[x][y])
            for x in range(5):
                for y in range(5):
                    st[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & M & B[(x + 2) % 5][y])
            st[0][0] ^= RC[rnd]
    out = b"".join(st[i % 5][i // 5].to_bytes(8, "little") for i in range(25))
    return out[:32]


def keccak256_hex(data: bytes) -> str:
    return "0x" + _keccak256(data).hex()


def validate_offer_id(offer_id: Any) -> str:
    if not isinstance(offer_id, str) or not UUID_V4_RE.match(offer_id):
        _fail(R_UUID, "$.offerId", "canonical lowercase hyphenated UUID v4 required")
    return offer_id


def offer_id_hash(offer_id: str) -> str:
    """offerIdHash = keccak256(UTF8(canonical lowercase hyphenated UUID v4))."""
    return keccak256_hex(validate_offer_id(offer_id).encode("utf-8"))


def prepare(artifact: Dict[str, Any]) -> Tuple[bytes, str, str]:
    """Return (canonicalBytes, offerHash, offerIdHash) for a valid artifact. Publish canonicalBytes verbatim."""
    cb = canonical_bytes(artifact)
    return cb, sha256_hex(cb), offer_id_hash(artifact["offerId"])
