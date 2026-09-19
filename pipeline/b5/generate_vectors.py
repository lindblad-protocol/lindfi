"""Generate the shared, versioned B5 FinancingOffer vector dataset consumed by BOTH implementations.

The generated file is DATA, not code: Python and TypeScript tests read it and must reproduce every
expected value. No expected hash is ever hard-coded in either test source.
"""
from __future__ import annotations

import base64
import copy
import json
from collections import OrderedDict

from financing_offer import (ArtifactValidationError, canonical_bytes, offer_hash, offer_id_hash,
                             sha256_hex, SPEC_SHA256)

ASSET_ID_HASH = "0x132b640977a078ed75c0a08f32d241ec1c1b023cb8cf51f3985c3065a3c36c25"
ASSESSMENT_HASH = "0x097eb0b6c000a45669558e48cdd7182625affe46f772c9e8e1071b6c77fdc4e7"
RECIPIENT = "0x4B432A562F71929925093896d67B355e1A3d7ceB"
USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
NOTICE = ("DEMO / TESTNET — NOT REAL FINANCING. Acceptance records agreement to proceed with the "
          "proposed financing terms. It does not represent loan origination, funding or settlement.")


def base(offer_id: str) -> dict:
    return {
        "schemaVersion": "1.0",
        "offerId": offer_id,
        "assetId": "LICO-0001",
        "lenderId": 1,
        "assessmentReference": {
            "assetIdHash": ASSET_ID_HASH,
            "assessmentIndex": "0",
            "assessmentHash": ASSESSMENT_HASH,
            "validUntil": "1792162800",
            "anchorIdHint": "12",
        },
        "recipient": RECIPIENT,
        "economics": {
            "principalAmount": "5000000000",
            "denomination": {"kind": "FIAT", "code": "USD", "decimals": 6},
            "settlement": {"kind": "ERC20", "chainId": 421614, "token": USDC, "decimals": 6, "symbol": "USDC"},
            "rateType": "FIXED",
            "rateBps": 850,
            "term": {"value": 180, "unit": "DAYS"},
        },
        "conditions": ["Lender conditions as free text; hash-protected; not machine-enforced in B5."],
        "issuedAt": 1789800000,
        "expiresAt": 1791000000,
        "statusAtIssuance": "ISSUED",
        "demoAtIssuance": True,
        "disclosure": "PUBLIC_DEMO",
        "recordHashAlgorithm": "SHA-256",
        "canonicalization": "RFC8785-JCS",
        "notice": NOTICE,
    }


def valid_fixture(fid: str, artifact: dict, note: str) -> dict:
    cb = canonical_bytes(artifact)
    return {
        "id": fid,
        "valid": True,
        "note": note,
        "input": artifact,
        "expectedCanonical": cb.decode("utf-8"),
        "expectedCanonicalBytesBase64": base64.b64encode(cb).decode("ascii"),
        "expectedCanonicalByteLength": len(cb),
        "expectedOfferHash": sha256_hex(cb),
        "offerId": artifact["offerId"],
        "expectedOfferIdHash": offer_id_hash(artifact["offerId"]),
    }


def invalid_fixture(fid: str, artifact: dict, note: str) -> dict:
    try:
        canonical_bytes(artifact)
        raise AssertionError(f"fixture {fid} was expected to be rejected but validated")
    except ArtifactValidationError as e:
        return {"id": fid, "valid": False, "note": note, "input": artifact,
                "expectedRejection": e.category, "expectedRejectionPath": e.path}


def build() -> dict:
    fixtures = []

    # A — canonical normal USD denomination / USDC settlement offer
    a = base("3f2a9c7e-5b41-4d2e-9a10-77c6b0e4d8f1")
    fixtures.append(valid_fixture("A-usd-denomination-usdc-settlement", a,
                                  "normal offer: USD denomination, USDC-on-Arbitrum settlement"))

    # B — same logical artifact, deliberately different input key order => identical canonical bytes
    b = OrderedDict()
    for k in reversed(list(a.keys())):
        v = a[k]
        if isinstance(v, dict):
            v = OrderedDict((kk, v[kk]) for kk in reversed(list(v.keys())))
        b[k] = v
    b_plain = json.loads(json.dumps(b))
    fB = valid_fixture("B-reversed-key-order", b_plain, "same logical artifact, reversed input key order")
    assert fB["expectedOfferHash"] == fixtures[0]["expectedOfferHash"], "key order must not affect the hash"
    assert fB["expectedCanonical"] == fixtures[0]["expectedCanonical"]
    fixtures.append(fB)

    # C — Unicode in conditions (accents, CJK, emoji, combining marks, escapes)
    c = base("5c1d4b8a-2e63-4f17-b0d9-1a2b3c4d5e6f")
    c["conditions"] = [
        "Garantía adicional requerida — José's lien, 50 % coverage",
        "担保条件：追加の保証が必要です",
        "Emoji boundary test 🏦⛏️  and combining: é vs é",
        "Escapes: quote \" backslash \\ tab \t newline \n",
    ]
    fixtures.append(valid_fixture("C-unicode-conditions", c, "Unicode, combining marks, emoji and escapes"))

    # D — permitted large integer decimal strings beyond the JS safe integer range
    d = base("9b7e2f10-4c55-4a3e-8d21-0f9e8d7c6b5a")
    d["economics"]["principalAmount"] = "9007199254740993000000"     # > 2^53-1
    d["assessmentReference"]["assessmentIndex"] = "18446744073709551615"
    fixtures.append(valid_fixture("D-large-decimal-strings", d,
                                  "large integers remain decimal strings, beyond Number.MAX_SAFE_INTEGER"))

    # E — malformed / non-canonical UUID
    e1 = base("3F2A9C7E-5B41-4D2E-9A10-77C6B0E4D8F1")                # uppercase
    fixtures.append(invalid_fixture("E1-uuid-uppercase", e1, "UUID must be lowercase"))
    e2 = base("3f2a9c7e5b414d2e9a1077c6b0e4d8f1")                    # unhyphenated
    fixtures.append(invalid_fixture("E2-uuid-unhyphenated", e2, "UUID must be hyphenated"))
    e3 = base("3f2a9c7e-5b41-1d2e-9a10-77c6b0e4d8f1")                # version nibble != 4
    fixtures.append(invalid_fixture("E3-uuid-not-v4", e3, "UUID must be version 4"))

    # F — forbidden float / unsafe numeric representation
    f1 = base("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
    f1["economics"]["principalAmount"] = 5000000000.5
    fixtures.append(invalid_fixture("F1-float-principal", f1, "floating point is never permitted"))
    f2 = base("2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e")
    f2["economics"]["principalAmount"] = 5000000000                  # number instead of decimal string
    fixtures.append(invalid_fixture("F2-principal-as-number", f2, "large integer must be a decimal string"))
    f3 = base("3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f")
    f3["economics"]["rateBps"] = 10001
    fixtures.append(invalid_fixture("F3-ratebps-out-of-bounds", f3, "rateBps must be 0..10000"))
    f4 = base("4d5e6f7a-8b9c-4d1e-9f2a-3b4c5d6e7f80")
    f4["economics"]["principalAmount"] = "0050"
    fixtures.append(invalid_fixture("F4-decimal-string-leading-zeros", f4, "no leading zeros in decimal strings"))

    # G — forbidden offerHash inside its own artifact
    g = base("5e6f7a8b-9c1d-4e2f-8a3b-4c5d6e7f8091")
    g["offerHash"] = "0x" + "ab" * 32
    fixtures.append(invalid_fixture("G-forbidden-offerhash", g, "offerHash must never be inside its own preimage"))

    # H — forbidden lender signature inside the artifact
    h = base("6f7a8b9c-1d2e-4f3a-9b4c-5d6e7f8091a2")
    h["lenderSignature"] = "0x" + "cd" * 65
    fixtures.append(invalid_fixture("H-forbidden-signature", h, "the signature lives on-chain, never in the artifact"))

    # I — mutable lifecycle status attempt
    i1 = base("7a8b9c1d-2e3f-4a5b-8c6d-7e8f9091a2b3")
    i1["status"] = "ACCEPTED"
    fixtures.append(invalid_fixture("I1-mutable-status-field", i1, "lifecycle state is a registry fact"))
    i2 = base("8b9c1d2e-3f4a-4b6c-9d7e-8f9091a2b3c4")
    i2["statusAtIssuance"] = "ACCEPTED"
    fixtures.append(invalid_fixture("I2-statusatissuance-not-issued", i2, "statusAtIssuance must be ISSUED"))

    # J — mutation of one economic term => different offerHash
    j = copy.deepcopy(a)
    j["economics"]["rateBps"] = 851
    fJ = valid_fixture("J-rate-mutation", j, "one basis point difference must change the offerHash")
    assert fJ["expectedOfferHash"] != fixtures[0]["expectedOfferHash"]
    fixtures.append(fJ)

    # K — additional coverage found useful during implementation: descriptor identity and empty structures
    k1 = base("9c1d2e3f-4a5b-4c7d-8e9f-9091a2b3c4d5")
    k1["economics"]["denomination"] = {"kind": "ERC20", "chainId": 421614, "token": USDC, "decimals": 6, "symbol": "USDC"}
    fixtures.append(valid_fixture("K1-usdc-denominated", k1,
                                  "USDC denomination: not comparable with a USD-scaled assessment"))
    k2 = base("1d2e3f4a-5b6c-4d8e-9f91-a2b3c4d5e6f7")
    k2["economics"]["settlement"] = {"kind": "NATIVE", "chainId": 421614, "decimals": 18}
    k2["conditions"] = []
    fixtures.append(valid_fixture("K2-native-settlement-empty-conditions", k2,
                                  "NATIVE settlement rail and an empty conditions array"))
    k3 = base("2e3f4a5b-6c7d-4e9f-8091-a2b3c4d5e6f8")
    k3["economics"]["settlement"] = {"kind": "ERC20", "chainId": 1, "token": USDC, "decimals": 6, "symbol": "USDC"}
    fK3 = valid_fixture("K3-same-token-different-chain", k3,
                        "same token address on chainId 1: a DIFFERENT settlement asset, different hash")
    assert fK3["expectedOfferHash"] != fixtures[0]["expectedOfferHash"]
    fixtures.append(fK3)
    k4 = base("3f4a5b6c-7d8e-4f91-a2b3-c4d5e6f8091a")
    k4["economics"]["denomination"] = {"kind": "FIAT", "code": "USD", "decimals": 6, "chainId": 421614}
    fixtures.append(invalid_fixture("K4-fiat-with-chainid", k4, "FIAT must not carry chainId"))
    k5 = base("4a5b6c7d-8e9f-4091-a2b3-c4d5e6f8091b")
    k5["expiresAt"] = k5["issuedAt"]
    fixtures.append(invalid_fixture("K5-expiry-not-after-issuance", k5, "expiresAt must be strictly after issuedAt"))

    return {
        "vectorsVersion": "1.0",
        "purpose": "Shared cross-language authority for B5 FinancingOffer canonicalization and hashing.",
        "specSha256": SPEC_SHA256,
        "canonicalization": "RFC8785-JCS",
        "hashAlgorithm": "SHA-256",
        "offerIdHashAlgorithm": "keccak256(UTF8(offerId))",
        "b4SerializationNote": ("B4 CollateralAssessment artifacts remain on their frozen pretty serialization "
                                "and are NOT affected by these vectors. RFC8785-JCS is authoritative only for "
                                "B5 FinancingOffer artifacts."),
        "fixtures": fixtures,
    }


if __name__ == "__main__":
    data = build()
    out = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    with open("financing_offer_vectors.v1.json", "w", encoding="utf-8") as fh:
        fh.write(out)
    valid = sum(1 for f in data["fixtures"] if f["valid"])
    print(f"fixtures: {len(data['fixtures'])} ({valid} valid / {len(data['fixtures']) - valid} invalid)")
    print("file sha256:", sha256_hex(out.encode("utf-8")))
