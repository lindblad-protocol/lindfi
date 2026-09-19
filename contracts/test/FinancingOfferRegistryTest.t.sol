// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";
import {LenderPolicyRegistry} from "../src/LenderPolicyRegistry.sol";
import {CollateralPositionAnchor} from "../src/CollateralPositionAnchor.sol";
import {FinancingOfferRegistry} from "../src/FinancingOfferRegistry.sol";
import {
    MockERC1271Wallet,
    RevertingERC1271Wallet,
    NonConformingERC1271Wallet,
    SilentContract,
    ValueSender
} from "./fixtures/MockERC1271Wallet.sol";

/// @notice B5-P4 — FinancingOfferRegistry against the REAL LR → LPR → CPA chain (no mocks for B4).
///         Mirrors the B4 test conventions: real dependency deployment in setUp, test_<Fn>_<Condition>
///         naming, custom-error revert assertions, heavy prank/warp usage.
contract FinancingOfferRegistryTest is Test {
    LenderRegistry lr;
    LenderPolicyRegistry lpr;
    CollateralPositionAnchor cpa;
    FinancingOfferRegistry reg;

    address governance = address(0xA11CE);
    uint256 lenderKey = 0xB0B;
    address lenderSigner;
    uint256 otherKey = 0xC0FFEE;
    address otherSigner;
    uint256 recipientKey = 0xD00D;
    address recipient;
    address relayer = address(0xBEEF);

    bytes32 constant ASSET_ID = keccak256("LICO-0001");
    bytes32 constant ASSESSMENT_HASH = keccak256("assessment-artifact-v1");
    bytes32 constant NAV_HASH = keccak256("nav");
    bytes32 constant POLICY_HASH = keccak256("policy");
    bytes32 constant USD = bytes32("USD");
    bytes32 constant ROLE = keccak256("PIPELINE-ANALYST");
    bytes32 constant OFFER_HASH = keccak256("offer-artifact-jcs-bytes");
    bytes32 constant OFFER_ID_HASH = keccak256("3f2a9c7e-5b41-4d2e-9a10-77c6b0e4d8f1");

    uint64 constant T0 = 1_800_000_000;
    uint64 constant PERFORMED_AT = T0 - 1 days;
    uint64 constant VALID_UNTIL = T0 + 30 days;

    function setUp() public {
        lenderSigner = vm.addr(lenderKey);
        otherSigner = vm.addr(otherKey);
        recipient = vm.addr(recipientKey);
        vm.warp(T0);

        lr = new LenderRegistry(governance);
        lpr = new LenderPolicyRegistry(governance, address(lr));
        cpa = new CollateralPositionAnchor(governance, address(lr), address(lpr));

        vm.startPrank(governance);
        lr.registerLender("Lindblad Demo Lender", "US-DE", LenderRegistry.KybStatus.VERIFIED, lenderSigner);
        vm.stopPrank();

        _anchor(ASSESSMENT_HASH, PERFORMED_AT, VALID_UNTIL);

        reg = new FinancingOfferRegistry(governance, address(lr), address(lpr), address(cpa));
    }

    //  helpers

    function _anchor(bytes32 assessmentHash, uint64 performedAt, uint64 validUntil) internal {
        CollateralPositionAnchor.AnchorInput memory a = CollateralPositionAnchor.AnchorInput({
            assetId: ASSET_ID,
            assessmentHash: assessmentHash,
            navHash: NAV_HASH,
            policyHash: POLICY_HASH,
            lenderId: 1,
            haircutBps: 2000,
            maxLTVBps: 5000,
            eligibleValue: 18_000_000_000,
            creditCapacity: 9_000_000_000,
            currencyCode: USD,
            verdict: 0,
            writerRole: ROLE,
            performedAt: performedAt,
            validUntil: validUntil,
            demoAtAnchoring: true
        });
        vm.prank(governance);
        cpa.anchorAssessment(a);
    }

    function _fiat() internal pure returns (FinancingOfferRegistry.AssetDescriptor memory) {
        return FinancingOfferRegistry.AssetDescriptor({
            kind: FinancingOfferRegistry.AssetKind.FIAT,
            code: USD,
            chainId: 0,
            token: address(0),
            decimals: 6
        });
    }

    function _erc20(uint256 chainId, address token) internal pure returns (FinancingOfferRegistry.AssetDescriptor memory) {
        return FinancingOfferRegistry.AssetDescriptor({
            kind: FinancingOfferRegistry.AssetKind.ERC20,
            code: bytes32(0),
            chainId: chainId,
            token: token,
            decimals: 6
        });
    }

    function _input() internal view returns (FinancingOfferRegistry.OfferInput memory) {
        return FinancingOfferRegistry.OfferInput({
            offerIdHash: OFFER_ID_HASH,
            offerHash: OFFER_HASH,
            assetId: ASSET_ID,
            assessmentIndex: 0,
            assessmentHash: ASSESSMENT_HASH,
            lenderId: 1,
            recipient: recipient,
            principalAmount: 5_000_000_000,
            denomination: _fiat(),
            settlement: _erc20(421614, address(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d)),
            rateBps: 850,
            rateType: FinancingOfferRegistry.RateType.FIXED,
            termValue: 180,
            termUnit: FinancingOfferRegistry.TermUnit.DAYS,
            issuedAt: T0,
            expiresAt: T0 + 10 days,
            demoAtIssuance: true,
            disclosure: FinancingOfferRegistry.Disclosure.PUBLIC_DEMO
        });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submit(FinancingOfferRegistry.OfferInput memory input, uint256 key, address sender)
        internal
        returns (uint256)
    {
        bytes memory sig = _sign(key, reg.offerDigest(input));
        vm.prank(sender);
        return reg.submitOffer(input, sig);
    }

    /// @dev vm.expectRevert binds to the NEXT call, so the digest view must run BEFORE it.
    function _expectSubmitRevert(FinancingOfferRegistry.OfferInput memory i, uint256 key, bytes4 sel) internal {
        bytes memory sig = _sign(key, reg.offerDigest(i));
        vm.expectRevert(sel);
        vm.prank(relayer);
        reg.submitOffer(i, sig);
    }

    function _expectSubmitRevertAny(FinancingOfferRegistry.OfferInput memory i, uint256 key) internal {
        bytes memory sig = _sign(key, reg.offerDigest(i));
        vm.expectRevert();
        vm.prank(relayer);
        reg.submitOffer(i, sig);
    }

    function _submitDefault() internal returns (uint256) {
        return _submit(_input(), lenderKey, relayer);
    }

    //  A — deployment and dependency identity

    function test_Constructor_BindsTheRealB4Dependencies() public view {
        assertEq(reg.lenderRegistry(), address(lr));
        assertEq(reg.lenderPolicyRegistry(), address(lpr));
        assertEq(reg.collateralPositionAnchor(), address(cpa));
        assertEq(reg.governance(), governance);
    }

    function test_Constructor_RevertsIfGovernanceMismatch() public {
        vm.expectRevert(FinancingOfferRegistry.LenderRegistryGovernanceMismatch.selector);
        new FinancingOfferRegistry(address(0xDEAD), address(lr), address(lpr), address(cpa));
    }

    function test_Constructor_RevertsIfAnchorRegistryMismatch() public {
        LenderRegistry lr2 = new LenderRegistry(governance);
        vm.expectRevert(FinancingOfferRegistry.AnchorRegistryMismatch.selector);
        new FinancingOfferRegistry(governance, address(lr2), address(lpr), address(cpa));
    }

    function test_Constructor_RevertsOnZeroAddresses() public {
        vm.expectRevert(FinancingOfferRegistry.ZeroGovernance.selector);
        new FinancingOfferRegistry(address(0), address(lr), address(lpr), address(cpa));
        vm.expectRevert(FinancingOfferRegistry.ZeroLenderRegistry.selector);
        new FinancingOfferRegistry(governance, address(0), address(lpr), address(cpa));
        vm.expectRevert(FinancingOfferRegistry.ZeroCollateralPositionAnchor.selector);
        new FinancingOfferRegistry(governance, address(lr), address(lpr), address(0));
    }

    //  B — valid issuance

    function test_SubmitOffer_AnchorsTheOfferWithContractSetProvenance() public {
        uint256 id = _submitDefault();
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        assertEq(id, 1);
        assertEq(r.offerHash, OFFER_HASH);
        assertEq(r.assetId, ASSET_ID);
        assertEq(r.assessmentIndex, 0);
        assertEq(r.assessmentHash, ASSESSMENT_HASH);
        assertEq(r.lenderId, 1);
        assertEq(r.issuerSigner, lenderSigner);
        assertEq(r.submittedBy, relayer, "submittedBy is the gas payer, never the issuer");
        assertEq(uint8(r.signatureKind), uint8(FinancingOfferRegistry.SignatureKind.ECDSA_EOA));
        assertEq(r.anchoredAt, T0);
        assertEq(uint8(r.status), uint8(FinancingOfferRegistry.Status.ISSUED));
        assertTrue(r.demoAtIssuance);
    }

    function test_SubmitOffer_RelayerIsNotTheIssuer() public {
        uint256 id = _submitDefault();
        assertTrue(reg.getOffer(id).issuerSigner != reg.getOffer(id).submittedBy);
    }

    function test_SubmitOffer_IndicesAndUniquenessMaps() public {
        uint256 id = _submitDefault();
        assertEq(reg.offerIdOf(OFFER_ID_HASH), id);
        assertEq(reg.offerOfHash(OFFER_HASH), id);
        assertEq(reg.countByAsset(ASSET_ID), 1);
        assertEq(reg.countByLender(1), 1);
        assertEq(reg.countByRecipient(recipient), 1);
        assertEq(reg.countByAssessment(ASSET_ID, 0), 1);
        assertEq(reg.offersByRecipient(recipient, 0, 10)[0], id);
        assertEq(reg.totalOffers(), 1);
    }

    function test_SubmitOffer_RevertsOnDuplicateOfferId() public {
        _submitDefault();
        FinancingOfferRegistry.OfferInput memory i2 = _input();
        i2.offerHash = keccak256("different-artifact");
        _expectSubmitRevert(i2, lenderKey, FinancingOfferRegistry.DuplicateOfferId.selector);
    }

    function test_SubmitOffer_RevertsOnDuplicateOfferHash() public {
        _submitDefault();
        FinancingOfferRegistry.OfferInput memory i2 = _input();
        i2.offerIdHash = keccak256("another-uuid");
        _expectSubmitRevert(i2, lenderKey, FinancingOfferRegistry.DuplicateOfferHash.selector);
    }

    function test_SubmitOffer_RevertsOnZeroFields() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.offerHash = bytes32(0);
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.ZeroOfferHash.selector);
        i = _input();
        i.recipient = address(0);
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.ZeroRecipient.selector);
        i = _input();
        i.principalAmount = 0;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.ZeroPrincipal.selector);
    }

    function test_SubmitOffer_RevertsOnInvalidEconomics() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.rateBps = 10_001;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.InvalidRateBps.selector);
        i = _input();
        i.termValue = 0;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.InvalidTerm.selector);
    }

    function test_SubmitOffer_AllowsRateBpsAt10_000() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.rateBps = 10_000;
        uint256 id = _submit(i, lenderKey, relayer);
        assertEq(reg.getOffer(id).rateBps, 10_000);
    }

    function test_SubmitOffer_RevertsOnInvalidAssetDescriptor() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.denomination.chainId = 421614; // FIAT must not carry a chainId
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.InvalidAssetDescriptor.selector);
        i = _input();
        i.settlement.token = address(0); // ERC20 requires a token
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.InvalidAssetDescriptor.selector);
    }

    //  C — assessment binding

    function test_SubmitOffer_RevertsOnWrongAssessmentHash() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.assessmentHash = keccak256("not-the-anchored-artifact");
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.AssessmentHashMismatch.selector);
    }

    function test_SubmitOffer_RevertsOnWrongAssessmentIndex() public {
        _anchor(keccak256("assessment-artifact-v2"), PERFORMED_AT, VALID_UNTIL);
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.assessmentIndex = 1; // exists, but holds a different assessmentHash
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.AssessmentHashMismatch.selector);
    }

    function test_SubmitOffer_RevertsOnOutOfRangeAssessmentIndex() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.assessmentIndex = 99;
        _expectSubmitRevertAny(i, lenderKey);
    }

    function test_SubmitOffer_RevertsOnWrongAsset() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.assetId = keccak256("OTHER-0001");
        _expectSubmitRevertAny(i, lenderKey);
    }

    function test_NewerAssessment_DoesNotReplaceTheReferencedHistoricalRecord() public {
        uint256 id = _submitDefault();
        // a newer anchor for the same (asset, lender) with a SHORTER validity
        _anchor(keccak256("assessment-artifact-v2"), PERFORMED_AT, T0 + 2 days);
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        assertEq(r.assessmentHash, ASSESSMENT_HASH, "reference must still point at the original record");
        assertEq(r.assessmentIndex, 0);
        // effectiveExpiry still derives from the REFERENCED record, not from latest()
        assertEq(reg.effectiveExpiry(id), T0 + 10 days);
        vm.warp(T0 + 5 days); // past the newer anchor's validity, inside the referenced one
        assertEq(uint8(reg.effectiveState(id, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.ISSUED));
    }

    function test_EffectiveExpiry_IsMinOfOfferAndAssessment() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.expiresAt = VALID_UNTIL + 10 days; // beyond the assessment
        uint256 id = _submit(i, lenderKey, relayer);
        assertEq(reg.effectiveExpiry(id), VALID_UNTIL, "assessment validity bounds the offer");
    }

    //  D — lender consistency

    function test_SubmitOffer_RevertsIfLenderInactive() public {
        vm.prank(governance);
        lr.deactivateLender(1);
        _expectSubmitRevert(_input(), lenderKey, FinancingOfferRegistry.LenderNotActive.selector);
    }

    function test_SubmitOffer_RevertsIfKybNotVerified() public {
        vm.prank(governance);
        lr.updateLender(1, "Lindblad Demo Lender", "US-DE", LenderRegistry.KybStatus.EXPIRED, lenderSigner);
        _expectSubmitRevert(_input(), lenderKey, FinancingOfferRegistry.LenderNotVerified.selector);
    }

    function test_SubmitOffer_RevertsIfAssessmentLenderDiffers() public {
        vm.prank(governance);
        lr.registerLender("Second Lender", "US-NY", LenderRegistry.KybStatus.VERIFIED, otherSigner);
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.lenderId = 2;
        _expectSubmitRevert(i, otherKey, FinancingOfferRegistry.AssessmentLenderMismatch.selector);
    }

    //  E — EIP-712

    function test_Digest_DomainBindsChainIdAndVerifyingContract() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LindFi FinancingOfferRegistry"),
                keccak256("1"),
                block.chainid,
                address(reg)
            )
        );
        assertEq(reg.domainSeparator(), expected);
    }

    function test_SubmitOffer_RevertsOnWrongSigner() public {
        bytes memory sig = _sign(otherKey, reg.offerDigest(_input()));
        vm.expectRevert(FinancingOfferRegistry.InvalidLenderSignature.selector);
        vm.prank(relayer);
        reg.submitOffer(_input(), sig);
    }

    function test_SubmitOffer_RevertsOnMutatedTermsAfterSigning() public {
        FinancingOfferRegistry.OfferInput memory signed = _input();
        bytes memory sig = _sign(lenderKey, reg.offerDigest(signed));
        FinancingOfferRegistry.OfferInput memory tampered = signed;
        tampered.principalAmount = 6_000_000_000; // relayer tries to change the amount
        vm.expectRevert(FinancingOfferRegistry.InvalidLenderSignature.selector);
        vm.prank(relayer);
        reg.submitOffer(tampered, sig);
    }

    function test_SubmitOffer_RevertsOnMutatedSettlementDescriptor() public {
        FinancingOfferRegistry.OfferInput memory signed = _input();
        bytes memory sig = _sign(lenderKey, reg.offerDigest(signed));
        FinancingOfferRegistry.OfferInput memory tampered = signed;
        tampered.settlement.chainId = 1; // same token, different chain
        vm.expectRevert(FinancingOfferRegistry.InvalidLenderSignature.selector);
        vm.prank(relayer);
        reg.submitOffer(tampered, sig);
    }

    function test_SubmitOffer_RevertsOnWrongVerifyingContract() public {
        FinancingOfferRegistry other = new FinancingOfferRegistry(governance, address(lr), address(lpr), address(cpa));
        bytes memory sig = _sign(lenderKey, other.offerDigest(_input())); // signed for the other contract
        vm.expectRevert(FinancingOfferRegistry.InvalidLenderSignature.selector);
        vm.prank(relayer);
        reg.submitOffer(_input(), sig);
    }

    function test_SubmitOffer_RevertsOnWrongChainId() public {
        bytes32 foreignDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LindFi FinancingOfferRegistry"),
                keccak256("1"),
                uint256(999999),
                address(reg)
            )
        );
        bytes32 structHash = keccak256(abi.encodePacked(reg.offerDigest(_input()))); // arbitrary struct hash
        bytes32 foreignDigest = keccak256(abi.encodePacked("\x19\x01", foreignDomain, structHash));
        bytes memory sig = _sign(lenderKey, foreignDigest);
        vm.expectRevert(FinancingOfferRegistry.InvalidLenderSignature.selector);
        vm.prank(relayer);
        reg.submitOffer(_input(), sig);
    }

    function test_SubmitOffer_RevertsOnEmptySignature() public {
        vm.expectRevert(FinancingOfferRegistry.EmptySignature.selector);
        vm.prank(relayer);
        reg.submitOffer(_input(), "");
    }

    function test_SubmitOffer_SignatureCannotBeReplayedForASecondOffer() public {
        bytes memory sig = _sign(lenderKey, reg.offerDigest(_input()));
        vm.prank(relayer);
        reg.submitOffer(_input(), sig);
        vm.expectRevert(FinancingOfferRegistry.DuplicateOfferId.selector);
        vm.prank(relayer);
        reg.submitOffer(_input(), sig);
    }

    //  F — EIP-1271

    function _registerContractLender(address wallet) internal returns (uint256) {
        vm.prank(governance);
        lr.registerLender("Contract Lender", "US-DE", LenderRegistry.KybStatus.VERIFIED, wallet);
        uint256 lenderId = lr.totalLenders();
        CollateralPositionAnchor.AnchorInput memory a = CollateralPositionAnchor.AnchorInput({
            assetId: ASSET_ID,
            assessmentHash: keccak256(abi.encode("assessment-for-lender", lenderId)),
            navHash: NAV_HASH,
            policyHash: POLICY_HASH,
            lenderId: uint32(lenderId),
            haircutBps: 2000,
            maxLTVBps: 5000,
            eligibleValue: 18_000_000_000,
            creditCapacity: 9_000_000_000,
            currencyCode: USD,
            verdict: 0,
            writerRole: ROLE,
            performedAt: PERFORMED_AT,
            validUntil: VALID_UNTIL,
            demoAtAnchoring: true
        });
        vm.prank(governance);
        cpa.anchorAssessment(a);
        return lenderId;
    }

    function _contractLenderInput(uint256 lenderId) internal view returns (FinancingOfferRegistry.OfferInput memory) {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.lenderId = lenderId;
        i.assessmentHash = keccak256(abi.encode("assessment-for-lender", lenderId));
        i.assessmentIndex = cpa.historyLength(ASSET_ID) - 1;
        i.offerIdHash = keccak256(abi.encode("uuid", lenderId));
        i.offerHash = keccak256(abi.encode("artifact", lenderId));
        return i;
    }

    function test_SubmitOffer_AcceptsValidErc1271ContractSigner() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(otherSigner);
        uint256 lenderId = _registerContractLender(address(wallet));
        FinancingOfferRegistry.OfferInput memory i = _contractLenderInput(lenderId);
        uint256 id = _submit(i, otherKey, relayer);
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        assertEq(uint8(r.signatureKind), uint8(FinancingOfferRegistry.SignatureKind.ERC1271_CONTRACT));
        assertEq(r.issuerSigner, address(wallet));
    }

    function test_SubmitOffer_RejectsInvalidErc1271Signature() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(otherSigner);
        uint256 lenderId = _registerContractLender(address(wallet));
        FinancingOfferRegistry.OfferInput memory i = _contractLenderInput(lenderId);
        _expectSubmitRevert(i, recipientKey, FinancingOfferRegistry.InvalidLenderSignature.selector); // signed by the wrong key
    }

    function test_SubmitOffer_RevertingErc1271SignerYieldsInvalidSignatureNotAGriefingRevert() public {
        RevertingERC1271Wallet wallet = new RevertingERC1271Wallet();
        uint256 lenderId = _registerContractLender(address(wallet));
        FinancingOfferRegistry.OfferInput memory i = _contractLenderInput(lenderId);
        _expectSubmitRevert(i, otherKey, FinancingOfferRegistry.InvalidLenderSignature.selector);
    }

    function test_SubmitOffer_NonConformingErc1271SignerIsInvalid() public {
        NonConformingERC1271Wallet wallet = new NonConformingERC1271Wallet();
        uint256 lenderId = _registerContractLender(address(wallet));
        FinancingOfferRegistry.OfferInput memory i = _contractLenderInput(lenderId);
        _expectSubmitRevert(i, otherKey, FinancingOfferRegistry.InvalidLenderSignature.selector);
    }

    function test_SubmitOffer_SilentContractSignerIsInvalid() public {
        SilentContract wallet = new SilentContract();
        uint256 lenderId = _registerContractLender(address(wallet));
        FinancingOfferRegistry.OfferInput memory i = _contractLenderInput(lenderId);
        _expectSubmitRevert(i, otherKey, FinancingOfferRegistry.InvalidLenderSignature.selector);
    }

    function test_Erc1271_HistoricalValidityIsRecordedAsAFactNotReproducedLater() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(otherSigner);
        uint256 lenderId = _registerContractLender(address(wallet));
        uint256 id = _submit(_contractLenderInput(lenderId), otherKey, relayer);
        // the signer contract is mutable: it can stop validating the very same signature
        wallet.setAccept(false);
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        // the RECORD still preserves that the configured contract signer validated it at issuance
        assertEq(uint8(r.signatureKind), uint8(FinancingOfferRegistry.SignatureKind.ERC1271_CONTRACT));
        assertEq(r.issuerSigner, address(wallet));
        assertGt(reg.getOfferSignature(id).length, 0);
        // and re-calling the signer today does NOT reproduce historical validity — by design
        assertTrue(wallet.isValidSignature(bytes32(0), "") != bytes4(0x1626ba7e));
    }

    //  G — lifecycle

    function test_AcceptOffer_RecipientAccepts() public {
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.acceptOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.ACCEPTED));
        assertEq(uint8(reg.effectiveState(id, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.ACCEPTED));
    }

    function test_DeclineOffer_RecipientDeclines() public {
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.declineOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.DECLINED));
    }

    function test_WithdrawOffer_LenderSignerWithdraws() public {
        uint256 id = _submitDefault();
        vm.prank(lenderSigner);
        reg.withdrawOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.WITHDRAWN));
    }

    function test_EffectiveState_ExpiresFromBlockTimeWithoutStoringATransition() public {
        uint256 id = _submitDefault();
        vm.warp(T0 + 10 days + 1);
        assertEq(uint8(reg.effectiveState(id, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.EXPIRED));
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.ISSUED), "EXPIRED is never stored");
    }

    function test_EffectiveState_BoundaryIsInclusiveAtEffectiveExpiry() public {
        uint256 id = _submitDefault();
        vm.warp(T0 + 10 days);
        assertEq(uint8(reg.effectiveState(id, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.ISSUED));
        vm.warp(T0 + 10 days + 1);
        assertEq(uint8(reg.effectiveState(id, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.EXPIRED));
    }

    function test_AcceptOffer_RevertsAfterExpiry() public {
        uint256 id = _submitDefault();
        vm.warp(T0 + 10 days + 1);
        vm.expectRevert(FinancingOfferRegistry.OfferExpired.selector);
        vm.prank(recipient);
        reg.acceptOffer(id);
    }

    function test_DeclineOffer_RevertsAfterExpiry() public {
        uint256 id = _submitDefault();
        vm.warp(T0 + 10 days + 1);
        vm.expectRevert(FinancingOfferRegistry.OfferExpired.selector);
        vm.prank(recipient);
        reg.declineOffer(id);
    }

    function test_WithdrawOffer_RevertsAfterExpiry() public {
        uint256 id = _submitDefault();
        vm.warp(T0 + 10 days + 1);
        vm.expectRevert(FinancingOfferRegistry.OfferExpired.selector);
        vm.prank(lenderSigner);
        reg.withdrawOffer(id);
    }

    function test_AcceptOffer_RevertsAfterAssessmentExpiry() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.expiresAt = VALID_UNTIL + 10 days;
        uint256 id = _submit(i, lenderKey, relayer);
        vm.warp(VALID_UNTIL + 1);
        vm.expectRevert(FinancingOfferRegistry.OfferExpired.selector);
        vm.prank(recipient);
        reg.acceptOffer(id);
    }

    function test_Lifecycle_ForbiddenTransitions() public {
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.acceptOffer(id);
        vm.expectRevert(FinancingOfferRegistry.InvalidOfferState.selector);
        vm.prank(recipient);
        reg.acceptOffer(id); // double accept
        vm.expectRevert(FinancingOfferRegistry.InvalidOfferState.selector);
        vm.prank(recipient);
        reg.declineOffer(id);
        vm.expectRevert(FinancingOfferRegistry.InvalidOfferState.selector);
        vm.prank(lenderSigner);
        reg.withdrawOffer(id); // withdrawal after acceptance is impossible
    }

    function test_Lifecycle_DeclineThenWithdrawIsRejected() public {
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.declineOffer(id);
        vm.expectRevert(FinancingOfferRegistry.InvalidOfferState.selector);
        vm.prank(lenderSigner);
        reg.withdrawOffer(id);
    }

    function test_Lifecycle_WrongRecipientCannotRespond() public {
        uint256 id = _submitDefault();
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(otherSigner);
        reg.acceptOffer(id);
    }

    function test_Lifecycle_LenderCannotAcceptAndRecipientCannotWithdraw() public {
        uint256 id = _submitDefault();
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(lenderSigner);
        reg.acceptOffer(id);
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(recipient);
        reg.withdrawOffer(id);
    }

    function test_Lifecycle_GovernanceCannotWithdraw() public {
        uint256 id = _submitDefault();
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(governance);
        reg.withdrawOffer(id);
    }

    function test_Lifecycle_UnknownOfferReverts() public {
        vm.expectRevert(FinancingOfferRegistry.OfferDoesNotExist.selector);
        reg.getOffer(42);
        assertEq(uint8(reg.effectiveState(42, uint64(block.timestamp))), uint8(FinancingOfferRegistry.OfferState.UNKNOWN));
    }

    //  H — signer rotation and historical provenance

    function test_SignerRotation_PreservesHistoricalIssuerAndSignature() public {
        uint256 id = _submitDefault();
        bytes memory sigBefore = reg.getOfferSignature(id);
        vm.prank(governance);
        lr.updateLender(1, "Lindblad Demo Lender", "US-DE", LenderRegistry.KybStatus.VERIFIED, otherSigner);
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        assertEq(r.issuerSigner, lenderSigner, "historical issuer is frozen");
        assertEq(keccak256(reg.getOfferSignature(id)), keccak256(sigBefore));
    }

    function test_SignerRotation_TransfersWithdrawalAuthorityToTheCurrentSigner() public {
        uint256 id = _submitDefault();
        vm.prank(governance);
        lr.updateLender(1, "Lindblad Demo Lender", "US-DE", LenderRegistry.KybStatus.VERIFIED, otherSigner);
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(lenderSigner); // the old signer no longer has authority
        reg.withdrawOffer(id);
        vm.prank(otherSigner);
        reg.withdrawOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.WITHDRAWN));
    }

    function test_HistoricalSignature_RemainsIndependentlyReproducibleForEoaSigners() public {
        uint256 id = _submitDefault();
        bytes memory sig = reg.getOfferSignature(id);
        bytes32 digest = reg.offerDigest(_input());
        (bytes32 r, bytes32 s, uint8 v) = _splitSig(sig);
        assertEq(ecrecover(digest, v, r, s), reg.getOffer(id).issuerSigner);
    }

    function _splitSig(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    //  I — lender deactivation

    function test_InactiveLender_CannotIssueButItsCurrentSignerMayStillWithdraw() public {
        uint256 id = _submitDefault();
        vm.prank(governance);
        lr.deactivateLender(1);
        // cannot issue
        FinancingOfferRegistry.OfferInput memory i2 = _input();
        i2.offerIdHash = keccak256("uuid-2");
        i2.offerHash = keccak256("artifact-2");
        _expectSubmitRevert(i2, lenderKey, FinancingOfferRegistry.LenderNotActive.selector);
        // cannot be accepted
        vm.expectRevert(FinancingOfferRegistry.LenderNotActive.selector);
        vm.prank(recipient);
        reg.acceptOffer(id);
        // BUT cleanup withdrawal remains possible
        vm.prank(lenderSigner);
        reg.withdrawOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.WITHDRAWN));
    }

    function test_KybExpiredLender_CleanupWithdrawalStillPossible() public {
        uint256 id = _submitDefault();
        vm.prank(governance);
        lr.updateLender(1, "Lindblad Demo Lender", "US-DE", LenderRegistry.KybStatus.EXPIRED, lenderSigner);
        vm.expectRevert(FinancingOfferRegistry.LenderNotVerified.selector);
        vm.prank(recipient);
        reg.acceptOffer(id);
        vm.prank(lenderSigner);
        reg.withdrawOffer(id);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.WITHDRAWN));
    }

    function test_DeclineRemainsPossibleWhileTheOfferIsUnexpiredEvenIfLenderIsInactive() public {
        uint256 id = _submitDefault();
        vm.prank(governance);
        lr.deactivateLender(1);
        vm.prank(recipient);
        reg.declineOffer(id); // refusal is never blocked by the lender's status
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.DECLINED));
    }

    //  J — relayed recipient responses and replay protection

    function _responseSig(uint256 id, uint8 response, uint64 deadline) internal view returns (bytes memory) {
        return _sign(recipientKey, reg.responseDigest(id, response, deadline));
    }

    function test_AcceptOfferFor_RelayedAcceptanceWorks() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        FinancingOfferRegistry.ResponseAuth memory auth =
            FinancingOfferRegistry.ResponseAuth({deadline: deadline, signature: _responseSig(id, 1, deadline)});
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.ACCEPTED));
    }

    function test_DeclineOfferFor_RelayedDeclineWorks() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        FinancingOfferRegistry.ResponseAuth memory auth =
            FinancingOfferRegistry.ResponseAuth({deadline: deadline, signature: _responseSig(id, 2, deadline)});
        vm.prank(relayer);
        reg.declineOfferFor(id, auth);
        assertEq(uint8(reg.getOffer(id).status), uint8(FinancingOfferRegistry.Status.DECLINED));
    }

    function test_RelayedResponse_RevertsWithWrongResponseCode() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        // a signature authorising DECLINE cannot be used to ACCEPT
        FinancingOfferRegistry.ResponseAuth memory auth =
            FinancingOfferRegistry.ResponseAuth({deadline: deadline, signature: _responseSig(id, 2, deadline)});
        vm.expectRevert(FinancingOfferRegistry.InvalidRecipientSignature.selector);
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth);
    }

    function test_RelayedResponse_RevertsAfterDeadline() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        FinancingOfferRegistry.ResponseAuth memory auth =
            FinancingOfferRegistry.ResponseAuth({deadline: deadline, signature: _responseSig(id, 1, deadline)});
        vm.warp(deadline + 1);
        vm.expectRevert(FinancingOfferRegistry.ResponseDeadlineExpired.selector);
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth);
    }

    function test_RelayedResponse_CannotBeReplayed() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        FinancingOfferRegistry.ResponseAuth memory auth =
            FinancingOfferRegistry.ResponseAuth({deadline: deadline, signature: _responseSig(id, 1, deadline)});
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth);
        assertTrue(reg.responseUsed(id));
        vm.expectRevert(FinancingOfferRegistry.ResponseAlreadyUsed.selector);
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth); // single-use: replay is rejected before any state check
    }

    function test_RelayedResponse_RevertsOnForgedRecipientSignature() public {
        uint256 id = _submitDefault();
        uint64 deadline = T0 + 1 days;
        FinancingOfferRegistry.ResponseAuth memory auth = FinancingOfferRegistry.ResponseAuth({
            deadline: deadline,
            signature: _sign(otherKey, reg.responseDigest(id, 1, deadline))
        });
        vm.expectRevert(FinancingOfferRegistry.InvalidRecipientSignature.selector);
        vm.prank(relayer);
        reg.acceptOfferFor(id, auth);
    }

    //  K — demo / disclosure consistency

    function test_SubmitOffer_RevertsIfDemoAtIssuanceIsFalse() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.demoAtIssuance = false;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.DemoRequired.selector);
    }

    function test_Record_CarriesTheDemoSemanticsTheArtifactDeclares() public {
        uint256 id = _submitDefault();
        FinancingOfferRegistry.OfferRecord memory r = reg.getOffer(id);
        assertTrue(r.demoAtIssuance);
        assertEq(uint8(r.disclosure), uint8(FinancingOfferRegistry.Disclosure.PUBLIC_DEMO));
    }

    //  L — zero funds

    function test_ZeroFunds_ContractCannotReceiveValue() public {
        ValueSender sender = new ValueSender();
        vm.deal(address(sender), 1 ether);
        bool ok = sender.sendTo{value: 1 ether}(address(reg));
        assertFalse(ok, "the registry must have no payable path");
        assertEq(address(reg).balance, 0);
    }

    function test_ZeroFunds_BalanceStaysZeroAcrossAFullLifecycle() public {
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.acceptOffer(id);
        assertEq(address(reg).balance, 0);
    }

    function test_ZeroFunds_DirectTransferToTheRegistryFails() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(reg).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(reg).balance, 0);
    }

    //  M — boundary and regression

    function test_Registry_NeverWritesToB4() public {
        uint256 lendersBefore = lr.totalLenders();
        uint256 anchorsBefore = cpa.totalAnchors();
        uint256 id = _submitDefault();
        vm.prank(recipient);
        reg.acceptOffer(id);
        assertEq(lr.totalLenders(), lendersBefore, "B4 lender state untouched");
        assertEq(cpa.totalAnchors(), anchorsBefore, "B4 anchor state untouched");
    }

    function test_Governance_TwoStepTransferDoesNotGrantOfferAuthority() public {
        uint256 id = _submitDefault();
        address newGov = address(0x6060);
        vm.prank(governance);
        reg.transferGovernance(newGov);
        vm.prank(newGov);
        reg.acceptGovernance();
        assertEq(reg.governance(), newGov);
        vm.expectRevert(FinancingOfferRegistry.NotAuthorized.selector);
        vm.prank(newGov);
        reg.withdrawOffer(id); // governance still has no commercial authority
    }

    function test_Pagination_ReturnsBoundedWindows() public {
        _submitDefault();
        FinancingOfferRegistry.OfferInput memory i2 = _input();
        i2.offerIdHash = keccak256("uuid-2");
        i2.offerHash = keccak256("artifact-2");
        _submit(i2, lenderKey, relayer);
        assertEq(reg.offersByAsset(ASSET_ID, 0, 1).length, 1);
        assertEq(reg.offersByAsset(ASSET_ID, 0, 10).length, 2);
        assertEq(reg.offersByAsset(ASSET_ID, 5, 10).length, 0);
    }

    function test_MultipleOffersFromTheSameLenderCoexist() public {
        uint256 a = _submitDefault();
        FinancingOfferRegistry.OfferInput memory i2 = _input();
        i2.offerIdHash = keccak256("uuid-2");
        i2.offerHash = keccak256("artifact-2");
        i2.principalAmount = 12_000_000_000; // above the assessed capacity: permitted on-chain
        uint256 b = _submit(i2, lenderKey, relayer);
        vm.prank(recipient);
        reg.acceptOffer(a);
        vm.prank(recipient);
        reg.declineOffer(b);
        assertEq(uint8(reg.getOffer(a).status), uint8(FinancingOfferRegistry.Status.ACCEPTED));
        assertEq(uint8(reg.getOffer(b).status), uint8(FinancingOfferRegistry.Status.DECLINED));
    }

    function test_SubmitOffer_RevertsIfIssuedAtIsInTheFuture() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.issuedAt = T0 + 1;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.IssuedAtInFuture.selector);
    }

    function test_SubmitOffer_RevertsIfIssuedBeforeTheAssessment() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.issuedAt = PERFORMED_AT - 1;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.IssuedBeforeAssessment.selector);
    }

    function test_SubmitOffer_RevertsIfExpiryNotAfterIssuance() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.expiresAt = i.issuedAt;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.InvalidValidityWindow.selector);
    }

    function test_SubmitOffer_RevertsIfAlreadyExpiredAtSubmission() public {
        FinancingOfferRegistry.OfferInput memory i = _input();
        i.issuedAt = PERFORMED_AT;
        i.expiresAt = PERFORMED_AT + 1 hours;
        _expectSubmitRevert(i, lenderKey, FinancingOfferRegistry.NotActionableAtSubmission.selector);
    }
}
