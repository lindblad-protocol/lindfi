"""B5-P3 — Python conformance against the SHARED vector dataset.

No expected hash is hard-coded here: every expectation comes from the vector file, which is the
single cross-language authority also consumed by the TypeScript verifier tests.
"""
from __future__ import annotations

import base64
import copy
import json
import os

import pytest

from financing_offer import (ArtifactValidationError, SPEC_SHA256, canonical_bytes, offer_hash,
                             offer_id_hash, sha256_hex, validate_artifact)

VECTORS_PATH = os.path.join(os.path.dirname(__file__), "financing_offer_vectors.v1.json")
with open(VECTORS_PATH, encoding="utf-8") as _fh:
    VECTORS = json.load(_fh)

FIXTURES = VECTORS["fixtures"]
VALID = [f for f in FIXTURES if f["valid"]]
INVALID = [f for f in FIXTURES if not f["valid"]]
BY_ID = {f["id"]: f for f in FIXTURES}


def ids(fs):
    return [f["id"] for f in fs]


def test_dataset_declares_the_frozen_conventions():
    assert VECTORS["specSha256"] == SPEC_SHA256
    assert VECTORS["canonicalization"] == "RFC8785-JCS"
    assert VECTORS["hashAlgorithm"] == "SHA-256"
    assert VALID and INVALID


@pytest.mark.parametrize("f", VALID, ids=ids(VALID))
def test_valid_fixture_canonical_bytes(f):
    cb = canonical_bytes(f["input"])
    assert cb.decode("utf-8") == f["expectedCanonical"]
    assert base64.b64encode(cb).decode("ascii") == f["expectedCanonicalBytesBase64"]
    assert len(cb) == f["expectedCanonicalByteLength"]


@pytest.mark.parametrize("f", VALID, ids=ids(VALID))
def test_valid_fixture_offer_hash(f):
    assert offer_hash(f["input"]) == f["expectedOfferHash"]


@pytest.mark.parametrize("f", VALID, ids=ids(VALID))
def test_valid_fixture_offer_id_hash(f):
    assert offer_id_hash(f["offerId"]) == f["expectedOfferIdHash"]


@pytest.mark.parametrize("f", INVALID, ids=ids(INVALID))
def test_invalid_fixture_is_rejected_before_canonicalization(f):
    with pytest.raises(ArtifactValidationError) as exc:
        canonical_bytes(f["input"])
    assert exc.value.category == f["expectedRejection"]
    assert exc.value.path == f["expectedRejectionPath"]


def test_key_order_does_not_change_the_canonical_form():
    a, b = BY_ID["A-usd-denomination-usdc-settlement"], BY_ID["B-reversed-key-order"]
    assert canonical_bytes(b["input"]) == canonical_bytes(a["input"])
    assert offer_hash(b["input"]) == offer_hash(a["input"])


def test_one_basis_point_changes_the_offer_hash():
    a, j = BY_ID["A-usd-denomination-usdc-settlement"], BY_ID["J-rate-mutation"]
    assert offer_hash(j["input"]) != offer_hash(a["input"])


def test_same_token_on_a_different_chain_is_a_different_artifact():
    a, k3 = BY_ID["A-usd-denomination-usdc-settlement"], BY_ID["K3-same-token-different-chain"]
    assert offer_hash(k3["input"]) != offer_hash(a["input"])


def test_validation_never_normalizes_the_artifact():
    a = BY_ID["A-usd-denomination-usdc-settlement"]["input"]
    before = copy.deepcopy(a)
    validate_artifact(a)
    assert a == before


def test_published_bytes_are_exactly_the_hashed_bytes():
    """The publisher must emit canonical_bytes verbatim; re-serializing is not permitted."""
    a = BY_ID["A-usd-denomination-usdc-settlement"]["input"]
    cb = canonical_bytes(a)
    assert sha256_hex(cb) == offer_hash(a)
    # a pretty re-serialization of the same logical artifact must NOT match the offerHash
    pretty = json.dumps(a, indent=2, ensure_ascii=False).encode("utf-8")
    assert sha256_hex(pretty) != offer_hash(a)


def test_offer_hash_is_never_inside_its_own_preimage():
    a = copy.deepcopy(BY_ID["A-usd-denomination-usdc-settlement"]["input"])
    a["offerHash"] = offer_hash(BY_ID["A-usd-denomination-usdc-settlement"]["input"])
    with pytest.raises(ArtifactValidationError) as exc:
        canonical_bytes(a)
    assert exc.value.category == "FORBIDDEN_OFFERHASH_FIELD"


def test_b4_pretty_convention_is_not_applied_to_b5():
    """B4 hashes pretty bytes; B5 hashes JCS bytes. The two must not be conflated."""
    a = BY_ID["A-usd-denomination-usdc-settlement"]["input"]
    b4_style = json.dumps(a, sort_keys=False, separators=(",", ": "), ensure_ascii=False).encode("utf-8")
    assert sha256_hex(b4_style) != offer_hash(a)
