// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Read-only view of the B4 LenderRegistry consumed by B5.
interface ILenderRegistry {
    enum KybStatus {
        NONE,
        PENDING,
        VERIFIED,
        REJECTED,
        EXPIRED
    }

    struct Lender {
        uint256 lenderId;
        string name;
        string jurisdiction;
        KybStatus kybStatus;
        address signerAddress;
        bool active;
        uint256 addedAt;
    }

    function governance() external view returns (address);
    function getLender(uint256 lenderId) external view returns (Lender memory);
}

/// @notice Read-only view of the B4 LenderPolicyRegistry consumed by B5.
interface ILenderPolicyRegistry {
    function governance() external view returns (address);
    function lenderRegistry() external view returns (address);
}

/// @notice Read-only view of the B4 CollateralPositionAnchor consumed by B5.
///         Only the SPECIFIC historical getter is used. latest() and state() are deliberately
///         absent from this interface so no code path can resolve an offer through them.
interface ICollateralPositionAnchor {
    struct AnchorRecord {
        bytes32 assetId;
        bytes32 assessmentHash;
        bytes32 navHash;
        bytes32 policyHash;
        uint32 lenderId;
        uint16 haircutBps;
        uint16 maxLTVBps;
        uint256 eligibleValue;
        uint256 creditCapacity;
        bytes32 currencyCode;
        uint8 verdict;
        address writer;
        bytes32 writerRole;
        uint64 performedAt;
        uint64 anchoredAt;
        uint64 validUntil;
        bool demoAtAnchoring;
    }

    function governance() external view returns (address);
    function lenderRegistry() external view returns (address);
    function lenderPolicyRegistry() external view returns (address);
    function getAssessment(bytes32 assetId, uint256 index) external view returns (AnchorRecord memory);
}

/// @title FinancingOfferRegistry
/// @notice B5 — Verifiable Financing Offer Layer. Anchors lender-issued, cryptographically
///         authenticated financing TERMS bound to one SPECIFIC CollateralAssessment record, and
///         records their lifecycle. It is strictly downstream and read-only with respect to B4.
///
/// @dev Frozen by LINDFI_B5_TECHNICAL_INTEGRATION_SPEC_v0.2.md
///      SHA-256 4eea6395924b5dbd34ae0368f49936f7441b4b16a455a31fe544343773b67be4
///
///      offerHash   = SHA-256(UTF8(RFC8785-JCS(artifact)))   — computed OFF-CHAIN (B5-P3)
///      offerIdHash = keccak256(UTF8(canonical lowercase hyphenated UUID v4))
///      The contract never canonicalizes or hashes an artifact; it anchors the derived identifiers
///      and binds them through the lender's EIP-712 signature. There is exactly one artifact hashing
///      convention in B5, and it lives off-chain.
///
///      ZERO FUNDS. This contract has no payable path, no receive, no fallback, no token interface,
///      no approval, transfer, escrow, origination, funding, repayment or liquidation logic, and no
///      rescue mechanism. ACCEPTED means the recipient accepted the proposed terms to progress toward
///      origination. It does not mean funded, disbursed, escrowed, originated or settled.
///
///      Explicitly absent: receive, fallback, delegatecall, selfdestruct, upgrade path, pause,
///      token interfaces, fund custody, any write to LenderRegistry, LenderPolicyRegistry or
///      CollateralPositionAnchor.
contract FinancingOfferRegistry {
    //  Types

    enum RateType {
        FIXED
    }

    enum TermUnit {
        DAYS,
        MONTHS
    }

    enum AssetKind {
        FIAT,
        NATIVE,
        ERC20
    }

    /// @notice Stored lifecycle status. EXPIRED is NEVER stored: it is derived from block time.
    enum Status {
        NONE,
        ISSUED,
        ACCEPTED,
        DECLINED,
        WITHDRAWN
    }

    /// @notice Effective lifecycle state returned by effectiveState().
    enum OfferState {
        UNKNOWN,
        ISSUED,
        ACCEPTED,
        DECLINED,
        WITHDRAWN,
        EXPIRED
    }

    /// @notice B5 MVP implements PUBLIC_DEMO only. RESTRICTED/PRIVATE are deferred, not faked.
    enum Disclosure {
        PUBLIC_DEMO
    }

    /// @notice How the lender signature was verified at issuance. Recorded because an EIP-1271
    ///         contract signer's validity is a fact about THAT MOMENT: re-calling isValidSignature
    ///         later may not reproduce it, since the signer contract is mutable. ECDSA recovery, by
    ///         contrast, stays independently reproducible forever.
    enum SignatureKind {
        NONE,
        ECDSA_EOA,
        ERC1271_CONTRACT
    }

    struct AssetDescriptor {
        AssetKind kind;
        bytes32 code; // FIAT: ASCII right-padded ISO-4217; otherwise bytes32(0)
        uint256 chainId; // ERC20/NATIVE: EVM chain id; FIAT: 0
        address token; // ERC20 only; otherwise address(0)
        uint8 decimals; // scale of amounts expressed in this asset
    }

    struct OfferRecord {
        // identity and provenance
        bytes32 offerIdHash;
        bytes32 offerHash;
        // assessment reference — specific, immutable, never latest()/state()
        bytes32 assetId;
        uint256 assessmentIndex;
        bytes32 assessmentHash;
        uint256 lenderId;
        address issuerSigner; // lender signer at issuance (historical, frozen)
        address submittedBy; // gas payer only — never the authenticated issuer
        SignatureKind signatureKind;
        // counterparty
        address recipient;
        // economics
        uint256 principalAmount;
        AssetDescriptor denomination;
        AssetDescriptor settlement;
        uint32 rateBps;
        RateType rateType;
        uint32 termValue;
        TermUnit termUnit;
        // lifecycle
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 anchoredAt; // contract-set
        uint64 respondedAt; // contract-set on ACCEPT/DECLINE/WITHDRAW
        Status status;
        bool demoAtIssuance;
        Disclosure disclosure;
    }

    struct OfferInput {
        bytes32 offerIdHash;
        bytes32 offerHash;
        bytes32 assetId;
        uint256 assessmentIndex;
        bytes32 assessmentHash;
        uint256 lenderId;
        address recipient;
        uint256 principalAmount;
        AssetDescriptor denomination;
        AssetDescriptor settlement;
        uint32 rateBps;
        RateType rateType;
        uint32 termValue;
        TermUnit termUnit;
        uint64 issuedAt;
        uint64 expiresAt;
        bool demoAtIssuance;
        Disclosure disclosure;
    }

    struct ResponseAuth {
        uint64 deadline;
        bytes signature;
    }

    //  Errors

    error ZeroGovernance();
    error ZeroLenderRegistry();
    error ZeroLenderPolicyRegistry();
    error ZeroCollateralPositionAnchor();
    error LenderRegistryGovernanceMismatch();
    error LenderPolicyRegistryGovernanceMismatch();
    error AnchorGovernanceMismatch();
    error AnchorRegistryMismatch();
    error AnchorPolicyRegistryMismatch();
    error NotGovernance();
    error NotPendingGovernance();
    error NotAuthorized();
    error ZeroOfferIdHash();
    error ZeroOfferHash();
    error ZeroAssetId();
    error ZeroAssessmentHash();
    error ZeroRecipient();
    error ZeroPrincipal();
    error EmptySignature();
    error InvalidRateType();
    error InvalidRateBps();
    error InvalidTerm();
    error InvalidAssetDescriptor();
    error UnsupportedDisclosure();
    error DemoRequired();
    error DuplicateOfferId();
    error DuplicateOfferHash();
    error OfferDoesNotExist();
    error AssessmentHashMismatch();
    error AssessmentAssetMismatch();
    error AssessmentLenderMismatch();
    error LenderNotActive();
    error LenderNotVerified();
    error LenderIdOutOfRange();
    error InvalidLenderSignature();
    error InvalidRecipientSignature();
    error ResponseDeadlineExpired();
    error ResponseAlreadyUsed();
    error IssuedAtInFuture();
    error IssuedBeforeAssessment();
    error InvalidValidityWindow();
    error NotActionableAtSubmission();
    error OfferExpired();
    error InvalidOfferState();

    //  Events

    event OfferSubmitted(
        uint256 indexed offerId,
        bytes32 indexed offerIdHash,
        uint256 indexed lenderId,
        bytes32 assetId,
        address recipient,
        uint64 issuedAt,
        uint64 expiresAt
    );
    event OfferProvenance(
        uint256 indexed offerId,
        bytes32 offerHash,
        bytes32 assetId,
        uint256 assessmentIndex,
        bytes32 assessmentHash,
        address issuerSigner,
        address submittedBy,
        SignatureKind signatureKind,
        bytes lenderSignature,
        bool demoAtIssuance
    );
    event OfferEconomics(
        uint256 indexed offerId,
        uint256 principalAmount,
        uint32 rateBps,
        RateType rateType,
        uint32 termValue,
        TermUnit termUnit,
        bytes32 denominationDigest,
        bytes32 settlementDigest
    );
    event OfferAccepted(uint256 indexed offerId, address indexed recipient, uint64 respondedAt, bool relayed);
    event OfferDeclined(uint256 indexed offerId, address indexed recipient, uint64 respondedAt, bool relayed);
    event OfferWithdrawn(uint256 indexed offerId, address indexed by, uint64 respondedAt);
    event GovernanceTransferStarted(address indexed current, address indexed pending);
    event GovernanceTransferred(address indexed previous, address indexed current);

    //  Immutable dependencies (B4, read-only)

    address public immutable lenderRegistry;
    address public immutable lenderPolicyRegistry;
    address public immutable collateralPositionAnchor;

    //  Governance (protocol infrastructure only — NEVER a commercial authority over offers)

    address public governance;
    address public pendingGovernance;

    //  EIP-712

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("LindFi FinancingOfferRegistry");
    bytes32 private constant VERSION_HASH = keccak256("1");

    bytes32 public constant FINANCING_OFFER_TYPEHASH = keccak256(
        "FinancingOffer(bytes32 offerIdHash,bytes32 offerHash,bytes32 assetId,uint256 assessmentIndex,bytes32 assessmentHash,uint256 lenderId,address recipient,uint256 principalAmount,uint32 rateBps,uint8 rateType,uint32 termValue,uint8 termUnit,bytes32 denominationDigest,bytes32 settlementDigest,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 public constant OFFER_RESPONSE_TYPEHASH =
        keccak256("OfferResponse(bytes32 offerIdHash,bytes32 offerHash,uint8 response,uint64 deadline)");

    uint8 private constant RESPONSE_ACCEPT = 1;
    uint8 private constant RESPONSE_DECLINE = 2;

    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;

    //  Storage

    uint256 private _nextOfferId = 1;
    mapping(uint256 => OfferRecord) private _offers;
    mapping(uint256 => bytes) private _signatures;
    mapping(bytes32 => uint256) public offerIdOf; // offerIdHash => offerId
    mapping(bytes32 => uint256) public offerOfHash; // offerHash  => offerId
    mapping(uint256 => bool) public responseUsed; // relayed response single-use
    mapping(bytes32 => uint256[]) private _byAsset;
    mapping(uint256 => uint256[]) private _byLender;
    mapping(address => uint256[]) private _byRecipient;
    mapping(bytes32 => uint256[]) private _byAssessment;

    //  Constructor — triangulation over the full B4 dependency graph

    constructor(address governance_, address lenderRegistry_, address lenderPolicyRegistry_, address anchor_) {
        if (governance_ == address(0)) revert ZeroGovernance();
        if (lenderRegistry_ == address(0)) revert ZeroLenderRegistry();
        if (lenderPolicyRegistry_ == address(0)) revert ZeroLenderPolicyRegistry();
        if (anchor_ == address(0)) revert ZeroCollateralPositionAnchor();

        if (ILenderRegistry(lenderRegistry_).governance() != governance_) revert LenderRegistryGovernanceMismatch();
        if (ILenderPolicyRegistry(lenderPolicyRegistry_).governance() != governance_) {
            revert LenderPolicyRegistryGovernanceMismatch();
        }
        if (ILenderPolicyRegistry(lenderPolicyRegistry_).lenderRegistry() != lenderRegistry_) {
            revert AnchorRegistryMismatch();
        }
        if (ICollateralPositionAnchor(anchor_).governance() != governance_) revert AnchorGovernanceMismatch();
        if (ICollateralPositionAnchor(anchor_).lenderRegistry() != lenderRegistry_) revert AnchorRegistryMismatch();
        if (ICollateralPositionAnchor(anchor_).lenderPolicyRegistry() != lenderPolicyRegistry_) {
            revert AnchorPolicyRegistryMismatch();
        }

        governance = governance_;
        lenderRegistry = lenderRegistry_;
        lenderPolicyRegistry = lenderPolicyRegistry_;
        collateralPositionAnchor = anchor_;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    //  Governance (two-step, B4 pattern). Governs infrastructure only.

    function transferGovernance(address newGovernance) external {
        if (msg.sender != governance) revert NotGovernance();
        if (newGovernance == address(0)) revert ZeroGovernance();
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotPendingGovernance();
        address previous = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceTransferred(previous, governance);
    }

    //  EIP-712 helpers

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice Domain separator, recomputed if the chain id changes (fork safety).
    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function descriptorDigest(AssetDescriptor memory d) public pure returns (bytes32) {
        return keccak256(abi.encode(d.kind, d.code, d.chainId, d.token, d.decimals));
    }

    /// @notice EIP-712 digest the lender signs. Exposed so any verifier can reproduce it off-chain.
    function offerDigest(OfferInput memory input) public view returns (bytes32) {
        // The 17 words are assembled into a fixed array and concatenated. abi.encodePacked over a
        // bytes32[17] is byte-identical to abi.encode of the same 17 words, so this is the exact
        // EIP-712 struct encoding; it is written this way only to keep the stack shallow under 0.8.20.
        bytes32[17] memory f;
        f[0] = FINANCING_OFFER_TYPEHASH;
        f[1] = input.offerIdHash;
        f[2] = input.offerHash;
        f[3] = input.assetId;
        f[4] = bytes32(input.assessmentIndex);
        f[5] = input.assessmentHash;
        f[6] = bytes32(input.lenderId);
        f[7] = bytes32(uint256(uint160(input.recipient)));
        f[8] = bytes32(input.principalAmount);
        f[9] = bytes32(uint256(input.rateBps));
        f[10] = bytes32(uint256(uint8(input.rateType)));
        f[11] = bytes32(uint256(input.termValue));
        f[12] = bytes32(uint256(uint8(input.termUnit)));
        f[13] = descriptorDigest(input.denomination);
        f[14] = descriptorDigest(input.settlement);
        f[15] = bytes32(uint256(input.issuedAt));
        f[16] = bytes32(uint256(input.expiresAt));
        return MessageHashUtils.toTypedDataHash(domainSeparator(), keccak256(abi.encodePacked(f)));
    }

    function responseDigest(uint256 offerId, uint8 response, uint64 deadline) public view returns (bytes32) {
        OfferRecord storage r = _offers[offerId];
        bytes32 structHash =
            keccak256(abi.encode(OFFER_RESPONSE_TYPEHASH, r.offerIdHash, r.offerHash, response, deadline));
        return MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
    }

    //  Issuance

    /// @notice Anchor a lender-signed FinancingOffer. The lender signer need NOT be msg.sender:
    ///         relayed submission is supported and the relayer gains no authority.
    function submitOffer(OfferInput calldata input, bytes calldata lenderSignature)
        external
        returns (uint256 offerId)
    {
        _validateInput(input);
        if (offerIdOf[input.offerIdHash] != 0) revert DuplicateOfferId();
        if (offerOfHash[input.offerHash] != 0) revert DuplicateOfferHash();

        ICollateralPositionAnchor.AnchorRecord memory anchor =
            ICollateralPositionAnchor(collateralPositionAnchor).getAssessment(input.assetId, input.assessmentIndex);
        if (anchor.assessmentHash != input.assessmentHash) revert AssessmentHashMismatch();
        if (anchor.assetId != input.assetId) revert AssessmentAssetMismatch();
        if (uint256(anchor.lenderId) != input.lenderId) revert AssessmentLenderMismatch();

        ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(input.lenderId);
        if (!lender.active) revert LenderNotActive();
        if (lender.kybStatus != ILenderRegistry.KybStatus.VERIFIED) revert LenderNotVerified();

        SignatureKind kind = _verifyLenderSignature(lender.signerAddress, offerDigest(input), lenderSignature);

        if (input.issuedAt > block.timestamp) revert IssuedAtInFuture();
        if (input.issuedAt < anchor.performedAt) revert IssuedBeforeAssessment();
        if (input.expiresAt <= input.issuedAt) revert InvalidValidityWindow();
        uint64 effective = input.expiresAt < anchor.validUntil ? input.expiresAt : anchor.validUntil;
        if (block.timestamp > effective) revert NotActionableAtSubmission();

        offerId = _nextOfferId++;
        OfferRecord storage r = _offers[offerId];
        r.offerIdHash = input.offerIdHash;
        r.offerHash = input.offerHash;
        r.assetId = input.assetId;
        r.assessmentIndex = input.assessmentIndex;
        r.assessmentHash = input.assessmentHash;
        r.lenderId = input.lenderId;
        r.issuerSigner = lender.signerAddress;
        r.submittedBy = msg.sender;
        r.signatureKind = kind;
        r.recipient = input.recipient;
        r.principalAmount = input.principalAmount;
        r.denomination = input.denomination;
        r.settlement = input.settlement;
        r.rateBps = input.rateBps;
        r.rateType = input.rateType;
        r.termValue = input.termValue;
        r.termUnit = input.termUnit;
        r.issuedAt = input.issuedAt;
        r.expiresAt = input.expiresAt;
        r.anchoredAt = uint64(block.timestamp);
        r.status = Status.ISSUED;
        r.demoAtIssuance = input.demoAtIssuance;
        r.disclosure = input.disclosure;
        _signatures[offerId] = lenderSignature;

        offerIdOf[input.offerIdHash] = offerId;
        offerOfHash[input.offerHash] = offerId;
        _byAsset[input.assetId].push(offerId);
        _byLender[input.lenderId].push(offerId);
        _byRecipient[input.recipient].push(offerId);
        _byAssessment[_assessmentKey(input.assetId, input.assessmentIndex)].push(offerId);

        _emitIssuance(offerId, input, lender.signerAddress, kind, lenderSignature);
    }

    /// @dev Emitting from a helper keeps submitOffer's stack within 0.8.20 limits.
    function _emitIssuance(
        uint256 offerId,
        OfferInput calldata input,
        address issuerSigner,
        SignatureKind kind,
        bytes calldata lenderSignature
    ) private {
        emit OfferSubmitted(
            offerId, input.offerIdHash, input.lenderId, input.assetId, input.recipient, input.issuedAt, input.expiresAt
        );
        emit OfferProvenance(
            offerId,
            input.offerHash,
            input.assetId,
            input.assessmentIndex,
            input.assessmentHash,
            issuerSigner,
            msg.sender,
            kind,
            lenderSignature,
            input.demoAtIssuance
        );
        emit OfferEconomics(
            offerId,
            input.principalAmount,
            input.rateBps,
            input.rateType,
            input.termValue,
            input.termUnit,
            descriptorDigest(input.denomination),
            descriptorDigest(input.settlement)
        );
    }

    function _validateInput(OfferInput calldata input) private pure {
        if (input.offerIdHash == bytes32(0)) revert ZeroOfferIdHash();
        if (input.offerHash == bytes32(0)) revert ZeroOfferHash();
        if (input.assetId == bytes32(0)) revert ZeroAssetId();
        if (input.assessmentHash == bytes32(0)) revert ZeroAssessmentHash();
        if (input.recipient == address(0)) revert ZeroRecipient();
        if (input.principalAmount == 0) revert ZeroPrincipal();
        if (input.rateType != RateType.FIXED) revert InvalidRateType();
        if (input.rateBps > 10_000) revert InvalidRateBps();
        if (input.termValue == 0) revert InvalidTerm();
        if (input.lenderId == 0 || input.lenderId > type(uint32).max) revert LenderIdOutOfRange();
        // B5 MVP freezes both disclosure fields to a single permitted value, so a record can never
        // contradict the artifact's demo semantics: any other value is rejected outright.
        if (input.disclosure != Disclosure.PUBLIC_DEMO) revert UnsupportedDisclosure();
        if (!input.demoAtIssuance) revert DemoRequired();
        _validateDescriptor(input.denomination);
        _validateDescriptor(input.settlement);
    }

    function _validateDescriptor(AssetDescriptor calldata d) private pure {
        if (d.decimals > 36) revert InvalidAssetDescriptor();
        if (d.kind == AssetKind.FIAT) {
            if (d.code == bytes32(0) || d.chainId != 0 || d.token != address(0)) revert InvalidAssetDescriptor();
        } else if (d.kind == AssetKind.NATIVE) {
            if (d.code != bytes32(0) || d.chainId == 0 || d.token != address(0)) revert InvalidAssetDescriptor();
        } else {
            if (d.code != bytes32(0) || d.chainId == 0 || d.token == address(0)) revert InvalidAssetDescriptor();
        }
    }

    /// @dev Verifies the lender signature and records HOW it was verified. A reverting or
    ///      non-conforming EIP-1271 signer yields an invalid signature, never a bubbled revert.
    function _verifyLenderSignature(address signer, bytes32 digest, bytes calldata signature)
        private
        view
        returns (SignatureKind)
    {
        if (signature.length == 0) revert EmptySignature();
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidLenderSignature();
        return signer.code.length == 0 ? SignatureKind.ECDSA_EOA : SignatureKind.ERC1271_CONTRACT;
    }

    //  Recipient actions

    function acceptOffer(uint256 offerId) external {
        _respond(offerId, RESPONSE_ACCEPT, msg.sender, false);
    }

    function declineOffer(uint256 offerId) external {
        _respond(offerId, RESPONSE_DECLINE, msg.sender, false);
    }

    function acceptOfferFor(uint256 offerId, ResponseAuth calldata auth) external {
        _authenticateRelayedResponse(offerId, RESPONSE_ACCEPT, auth);
        _respond(offerId, RESPONSE_ACCEPT, _offers[offerId].recipient, true);
    }

    function declineOfferFor(uint256 offerId, ResponseAuth calldata auth) external {
        _authenticateRelayedResponse(offerId, RESPONSE_DECLINE, auth);
        _respond(offerId, RESPONSE_DECLINE, _offers[offerId].recipient, true);
    }

    function _authenticateRelayedResponse(uint256 offerId, uint8 response, ResponseAuth calldata auth) private {
        OfferRecord storage r = _offers[offerId];
        if (r.status == Status.NONE) revert OfferDoesNotExist();
        if (auth.deadline < block.timestamp) revert ResponseDeadlineExpired();
        if (responseUsed[offerId]) revert ResponseAlreadyUsed();
        if (!SignatureChecker.isValidSignatureNow(r.recipient, responseDigest(offerId, response, auth.deadline), auth.signature))
        {
            revert InvalidRecipientSignature();
        }
        responseUsed[offerId] = true;
    }

    function _respond(uint256 offerId, uint8 response, address responder, bool relayed) private {
        OfferRecord storage r = _offers[offerId];
        if (r.status == Status.NONE) revert OfferDoesNotExist();
        if (r.status != Status.ISSUED) revert InvalidOfferState();
        // EXPIRED is terminal for every action: it is never overwritten by another terminal state.
        if (block.timestamp > effectiveExpiry(offerId)) revert OfferExpired();
        if (responder != r.recipient) revert NotAuthorized();

        if (response == RESPONSE_ACCEPT) {
            ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(r.lenderId);
            if (!lender.active) revert LenderNotActive();
            if (lender.kybStatus != ILenderRegistry.KybStatus.VERIFIED) revert LenderNotVerified();
            r.status = Status.ACCEPTED;
        } else {
            r.status = Status.DECLINED;
        }
        r.respondedAt = uint64(block.timestamp);

        if (response == RESPONSE_ACCEPT) {
            emit OfferAccepted(offerId, r.recipient, r.respondedAt, relayed);
        } else {
            emit OfferDeclined(offerId, r.recipient, r.respondedAt, relayed);
        }
    }

    //  Lender withdrawal

    /// @notice Withdraw an outstanding ISSUED offer. Lender-side only: GOVERNANCE CANNOT WITHDRAW.
    ///         Authority follows the lender's CURRENT signer, so rotation transfers it, while
    ///         issuerSigner preserves who authenticated the offer at issuance.
    ///         Frozen cleanup rule: an inactive or no-longer-VERIFIED lender's current signer MAY
    ///         still withdraw, even though it may not issue and its offers may not be accepted.
    function withdrawOffer(uint256 offerId) external {
        OfferRecord storage r = _offers[offerId];
        if (r.status == Status.NONE) revert OfferDoesNotExist();
        if (r.status != Status.ISSUED) revert InvalidOfferState();
        if (block.timestamp > effectiveExpiry(offerId)) revert OfferExpired();

        ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(r.lenderId);
        if (msg.sender != lender.signerAddress) revert NotAuthorized();

        r.status = Status.WITHDRAWN;
        r.respondedAt = uint64(block.timestamp);
        emit OfferWithdrawn(offerId, msg.sender, r.respondedAt);
    }

    //  Views

    function _assessmentKey(bytes32 assetId, uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encode(assetId, index));
    }

    /// @notice min(offer.expiresAt, referenced assessment validUntil), read from the SPECIFIC record.
    function effectiveExpiry(uint256 offerId) public view returns (uint64) {
        OfferRecord storage r = _offers[offerId];
        if (r.status == Status.NONE) revert OfferDoesNotExist();
        ICollateralPositionAnchor.AnchorRecord memory anchor =
            ICollateralPositionAnchor(collateralPositionAnchor).getAssessment(r.assetId, r.assessmentIndex);
        return r.expiresAt < anchor.validUntil ? r.expiresAt : anchor.validUntil;
    }

    /// @notice Effective state at an explicit timestamp. The caller supplies authoritative block time.
    function effectiveState(uint256 offerId, uint64 atTimestamp) public view returns (OfferState) {
        OfferRecord storage r = _offers[offerId];
        if (r.status == Status.NONE) return OfferState.UNKNOWN;
        if (r.status == Status.ACCEPTED) return OfferState.ACCEPTED;
        if (r.status == Status.DECLINED) return OfferState.DECLINED;
        if (r.status == Status.WITHDRAWN) return OfferState.WITHDRAWN;
        if (atTimestamp > effectiveExpiry(offerId)) return OfferState.EXPIRED;
        return OfferState.ISSUED;
    }

    function getOffer(uint256 offerId) external view returns (OfferRecord memory) {
        OfferRecord memory r = _offers[offerId];
        if (r.status == Status.NONE) revert OfferDoesNotExist();
        return r;
    }

    /// @notice The lender signature exactly as presented at issuance, kept on-chain so historical
    ///         authenticity remains provable without depending on logs, indexers or archive nodes.
    function getOfferSignature(uint256 offerId) external view returns (bytes memory) {
        if (_offers[offerId].status == Status.NONE) revert OfferDoesNotExist();
        return _signatures[offerId];
    }

    function totalOffers() external view returns (uint256) {
        return _nextOfferId - 1;
    }

    function _page(uint256[] storage ids, uint256 start, uint256 limit) private view returns (uint256[] memory out) {
        uint256 n = ids.length;
        if (start >= n) return new uint256[](0);
        uint256 end = start + limit;
        if (end > n) end = n;
        out = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = ids[i];
        }
    }

    function offersByAsset(bytes32 assetId, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byAsset[assetId], start, limit);
    }

    function offersByLender(uint256 lenderId, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byLender[lenderId], start, limit);
    }

    function offersByRecipient(address recipient, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory)
    {
        return _page(_byRecipient[recipient], start, limit);
    }

    function offersByAssessment(bytes32 assetId, uint256 assessmentIndex, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory)
    {
        return _page(_byAssessment[_assessmentKey(assetId, assessmentIndex)], start, limit);
    }

    function countByAsset(bytes32 assetId) external view returns (uint256) {
        return _byAsset[assetId].length;
    }

    function countByLender(uint256 lenderId) external view returns (uint256) {
        return _byLender[lenderId].length;
    }

    function countByRecipient(address recipient) external view returns (uint256) {
        return _byRecipient[recipient].length;
    }

    function countByAssessment(bytes32 assetId, uint256 assessmentIndex) external view returns (uint256) {
        return _byAssessment[_assessmentKey(assetId, assessmentIndex)].length;
    }

    //  Explicitly absent: receive, fallback, delegatecall, selfdestruct, upgrade path, pause, token
    //  interfaces, approvals, transfers, escrow, origination, funding, repayment, liquidation and any
    //  rescue mechanism. This contract can neither receive nor move value.
}
