// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Minimal interface into LenderRegistry required by
///         CollateralPositionAnchor. Mirrors the corresponding types
///         and functions of contracts/src/LenderRegistry.sol.
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

/// @notice Minimal interface into LenderPolicyRegistry required by
///         CollateralPositionAnchor. Used ONLY at construction time for
///         governance/registry triangulation. No runtime policyHash
///         verification is performed.
interface ILenderPolicyRegistry {
    function governance() external view returns (address);
    function lenderRegistry() external view returns (address);
}

/// @title CollateralPositionAnchor
/// @notice Anchors the outputs of the deterministic off-chain collateral
///         assessment pipeline on-chain. Stores both cryptographic
///         commitments (assessmentHash, navHash, policyHash) and the
///         resulting financial assessment values (haircutBps, maxLTVBps,
///         eligibleValue, creditCapacity, currencyCode, verdict).
/// @dev The contract does NOT calculate any financial value. Deterministic
///      calculation is off-chain. The contract receives and anchors the
///      resulting bundle.
///
///      Architectural boundary — the anchored output is:
///        NOT loan approval, NOT capital commitment, NOT loan offer.
///
///      Governance model follows MVP03A_GOVERNANCE_AMENDMENT_01:
///        - governance supplied at construction (rejects address(0))
///        - two-step transfer via transferGovernance + acceptGovernance
///        - governance() / pendingGovernance() satisfied by public storage
///
///      Deployment follows DEPLOY_GUARDRAIL_SPEC extended with
///      cross-dependency triangulation. The constructor independently
///      enforces internal consistency between the supplied governance,
///      LenderRegistry, and LenderPolicyRegistry. Canonical Safe
///      enforcement remains the responsibility of the deployment
///      guardrail and Constants.expectedSafeFor(block.chainid).
contract CollateralPositionAnchor {
    // ─── Types ─────────────────────────────────────────────────────

    /// @notice Frozen 17-field record. Field order and types are
    ///         locked; do not modify. Two of the seventeen fields
    ///         (writer, anchoredAt) are contract-set and never appear
    ///         in AnchorInput.
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

    /// @notice Input DTO for anchorAssessment. Exactly 15 caller-supplied
    ///         fields. `writer` and `anchoredAt` are intentionally
    ///         absent: they are always contract-set (writer = msg.sender,
    ///         anchoredAt = block.timestamp).
    /// @dev Rationale: groups the 15 caller-supplied fields into a
    ///      calldata DTO to avoid Solidity 0.8.20 stack-depth pressure
    ///      while preserving the frozen AnchorRecord and all protocol
    ///      semantics. ABI shape decision only; does not alter the
    ///      assessment data model. Field names and types match the
    ///      corresponding AnchorRecord fields verbatim.
    struct AnchorInput {
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
        bytes32 writerRole;
        uint64 performedAt;
        uint64 validUntil;
        bool demoAtAnchoring;
    }

    /// @notice Snapshot state returned by state(assetId, lenderId, atTimestamp).
    enum State {
        UNKNOWN,
        ACTIVE,
        EXPIRED
    }

    // ─── Storage ───────────────────────────────────────────────────

    /// @notice Current governance address. Two-step transfer authority.
    address public governance;

    /// @notice Address awaiting acceptGovernance() to become the new
    ///         governance. Zero when no transfer is pending.
    address public pendingGovernance;

    /// @notice The LenderRegistry contract this anchor composes with.
    address public immutable lenderRegistry;

    /// @notice The LenderPolicyRegistry contract this anchor composes
    ///         with. Used only for constructor triangulation; no
    ///         runtime policyHash verification is performed against it.
    address public immutable lenderPolicyRegistry;

    /// @dev Next anchor id to assign. Monotonic, never decremented.
    ///      Explicitly starts at 1 so that anchor id 0 remains the
    ///      "unassigned" sentinel.
    uint256 private _nextAnchorId = 1;

    /// @dev Canonical store of all anchor records by anchor id.
    mapping(uint256 => AnchorRecord) private _records;

    /// @dev Per-asset history: ordered list of anchor ids for an
    ///      assetId. Length grows by one per anchor for that asset.
    ///      Ordering equals chronological insertion order because
    ///      anchoredAt = block.timestamp is monotonic.
    mapping(bytes32 => uint256[]) private _byAsset;

    /// @dev Per-(asset, lender) history: ordered list of anchor ids
    ///      for the pair. Length grows by one per anchor for the pair.
    mapping(bytes32 => mapping(uint32 => uint256[])) private _byAssetLender;

    // ─── Events ────────────────────────────────────────────────────

    event AssessmentAnchored(
        uint256 indexed anchorId,
        bytes32 indexed assetId,
        uint32 indexed lenderId,
        uint8 verdict,
        address writer,
        bytes32 writerRole,
        uint64 anchoredAt,
        uint64 validUntil
    );

    event AssessmentHashes(uint256 indexed anchorId, bytes32 assessmentHash, bytes32 navHash, bytes32 policyHash);

    event AssessmentAmounts(
        uint256 indexed anchorId,
        uint16 haircutBps,
        uint16 maxLTVBps,
        uint256 eligibleValue,
        uint256 creditCapacity,
        bytes32 currencyCode,
        uint64 performedAt,
        bool demoAtAnchoring
    );

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    // ─── Custom errors ─────────────────────────────────────────────

    // Governance / construction
    error ZeroGovernance();
    error ZeroLenderRegistry();
    error ZeroLenderPolicyRegistry();
    error LenderRegistryGovernanceMismatch(address actual, address expected);
    error LenderPolicyRegistryGovernanceMismatch(address actual, address expected);
    error LenderPolicyRegistryRegistryMismatch(address actual, address expected);
    error NotGovernance();
    error NotPendingGovernance();

    // Frozen validation
    error ZeroAssessmentHash();
    error ZeroNavHash();
    error ZeroPolicyHash();
    error ZeroCurrencyCode();
    error InvalidValidityWindow(uint64 performedAt, uint64 validUntil);
    error CreditCapacityExceedsEligibleValue(uint256 creditCapacity, uint256 eligibleValue);

    // Approved additional validation
    error InvalidVerdict(uint8 verdict);
    error InvalidHaircutBps(uint16 haircutBps);
    error InvalidMaxLTVBps(uint16 maxLTVBps);
    error ZeroWriterRole();

    // Lender dependency (from LenderRegistry composition)
    error LenderNotActive(uint32 lenderId);
    error LenderNotVerified(uint32 lenderId);

    // Read failures
    error NoAnchorForPair(bytes32 assetId, uint32 lenderId);
    error NoAnchorForAsset(bytes32 assetId);
    error IndexOutOfBounds(bytes32 assetId, uint256 index);

    // ─── Modifiers ─────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────

    /// @param _governance Canonical governance for the target network.
    ///        Must be non-zero.
    /// @param _lenderRegistry Address of the deployed LenderRegistry.
    ///        Must be non-zero and its governance() must equal
    ///        _governance.
    /// @param _lenderPolicyRegistry Address of the deployed
    ///        LenderPolicyRegistry. Must be non-zero, its governance()
    ///        must equal _governance, AND its lenderRegistry() must
    ///        equal _lenderRegistry (triangulation guardrail).
    constructor(address _governance, address _lenderRegistry, address _lenderPolicyRegistry) {
        if (_governance == address(0)) revert ZeroGovernance();
        if (_lenderRegistry == address(0)) revert ZeroLenderRegistry();
        if (_lenderPolicyRegistry == address(0)) revert ZeroLenderPolicyRegistry();

        address lrGov = ILenderRegistry(_lenderRegistry).governance();
        if (lrGov != _governance) {
            revert LenderRegistryGovernanceMismatch(lrGov, _governance);
        }

        address lprGov = ILenderPolicyRegistry(_lenderPolicyRegistry).governance();
        if (lprGov != _governance) {
            revert LenderPolicyRegistryGovernanceMismatch(lprGov, _governance);
        }

        address lprLR = ILenderPolicyRegistry(_lenderPolicyRegistry).lenderRegistry();
        if (lprLR != _lenderRegistry) {
            revert LenderPolicyRegistryRegistryMismatch(lprLR, _lenderRegistry);
        }

        governance = _governance;
        lenderRegistry = _lenderRegistry;
        lenderPolicyRegistry = _lenderPolicyRegistry;
    }

    // ─── Write action ──────────────────────────────────────────────

    /// @notice Anchor a collateral assessment produced by the
    ///         deterministic off-chain pipeline.
    /// @dev Governance-only. Contract does not compute any financial
    ///      value. writer is msg.sender; anchoredAt is
    ///      uint64(block.timestamp). No runtime policyHash verification
    ///      is performed against LenderPolicyRegistry.
    /// @param input The 15 caller-supplied fields as a calldata DTO.
    /// @return anchorId Newly assigned monotonic id (starts at 1).
    function anchorAssessment(AnchorInput calldata input) external onlyGovernance returns (uint256 anchorId) {
        // 2. Frozen validations
        if (input.assessmentHash == bytes32(0)) revert ZeroAssessmentHash();
        if (input.navHash == bytes32(0)) revert ZeroNavHash();
        if (input.policyHash == bytes32(0)) revert ZeroPolicyHash();
        if (input.currencyCode == bytes32(0)) revert ZeroCurrencyCode();
        if (input.validUntil <= input.performedAt) {
            revert InvalidValidityWindow(input.performedAt, input.validUntil);
        }
        if (input.creditCapacity > input.eligibleValue) {
            revert CreditCapacityExceedsEligibleValue(input.creditCapacity, input.eligibleValue);
        }

        // 3. Approved additional validations
        if (input.verdict > 2) revert InvalidVerdict(input.verdict);
        if (input.haircutBps > 10_000) revert InvalidHaircutBps(input.haircutBps);
        if (input.maxLTVBps > 10_000) revert InvalidMaxLTVBps(input.maxLTVBps);
        if (input.writerRole == bytes32(0)) revert ZeroWriterRole();

        // 4. Lender dependency check via LenderRegistry
        //    LenderRegistry.getLender reverts LenderDoesNotExist if the
        //    lender does not exist; that revert bubbles up.
        ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(uint256(input.lenderId));
        if (!lender.active) revert LenderNotActive(input.lenderId);
        if (lender.kybStatus != ILenderRegistry.KybStatus.VERIFIED) {
            revert LenderNotVerified(input.lenderId);
        }

        // 5. Assign anchor id (no unchecked)
        anchorId = _nextAnchorId;
        _nextAnchorId = anchorId + 1;

        // 6. Store the frozen 17-field record
        _records[anchorId] = AnchorRecord({
            assetId: input.assetId,
            assessmentHash: input.assessmentHash,
            navHash: input.navHash,
            policyHash: input.policyHash,
            lenderId: input.lenderId,
            haircutBps: input.haircutBps,
            maxLTVBps: input.maxLTVBps,
            eligibleValue: input.eligibleValue,
            creditCapacity: input.creditCapacity,
            currencyCode: input.currencyCode,
            verdict: input.verdict,
            writer: msg.sender,
            writerRole: input.writerRole,
            performedAt: input.performedAt,
            anchoredAt: uint64(block.timestamp),
            validUntil: input.validUntil,
            demoAtAnchoring: input.demoAtAnchoring
        });

        // 7. Update indices
        _byAsset[input.assetId].push(anchorId);
        _byAssetLender[input.assetId][input.lenderId].push(anchorId);

        // 8. Emit the 3-event split
        emit AssessmentAnchored(
            anchorId,
            input.assetId,
            input.lenderId,
            input.verdict,
            msg.sender,
            input.writerRole,
            uint64(block.timestamp),
            input.validUntil
        );
        emit AssessmentHashes(anchorId, input.assessmentHash, input.navHash, input.policyHash);
        emit AssessmentAmounts(
            anchorId,
            input.haircutBps,
            input.maxLTVBps,
            input.eligibleValue,
            input.creditCapacity,
            input.currencyCode,
            input.performedAt,
            input.demoAtAnchoring
        );
    }

    // ─── Governance transfer (two-step, per Amendment 01) ──────────

    /// @notice Initiate a governance transfer. The new governance is
    ///         stored as pending and must call acceptGovernance to
    ///         complete the transfer.
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroGovernance();
        pendingGovernance = newGovernance;
        emit GovernanceTransferInitiated(governance, newGovernance);
    }

    /// @notice Accept a pending governance transfer.
    function acceptGovernance() external {
        address pending = pendingGovernance;
        if (pending == address(0) || msg.sender != pending) {
            revert NotPendingGovernance();
        }
        address previous = governance;
        governance = pending;
        pendingGovernance = address(0);
        emit GovernanceTransferred(previous, pending);
    }

    // ─── Read functions ────────────────────────────────────────────

    /// @notice Return the most recent anchor record for the given
    ///         (assetId, lenderId) pair.
    /// @dev STRICT: reverts NoAnchorForPair if no record exists.
    function latest(bytes32 assetId, uint32 lenderId) external view returns (AnchorRecord memory) {
        uint256[] storage ids = _byAssetLender[assetId][lenderId];
        uint256 n = ids.length;
        if (n == 0) revert NoAnchorForPair(assetId, lenderId);
        return _records[ids[n - 1]];
    }

    /// @notice Return the most recently anchored record for the given
    ///         asset, across all lenders.
    /// @dev STRICT: reverts NoAnchorForAsset if no record exists.
    function latest(bytes32 assetId) external view returns (AnchorRecord memory) {
        uint256[] storage ids = _byAsset[assetId];
        uint256 n = ids.length;
        if (n == 0) revert NoAnchorForAsset(assetId);
        return _records[ids[n - 1]];
    }

    /// @notice Total number of records for the given asset, across
    ///         all lenders. Non-reverting.
    function historyLength(bytes32 assetId) external view returns (uint256) {
        return _byAsset[assetId].length;
    }

    /// @notice Total number of records for the given (asset, lender)
    ///         pair. Non-reverting.
    function historyLength(bytes32 assetId, uint32 lenderId) external view returns (uint256) {
        return _byAssetLender[assetId][lenderId].length;
    }

    /// @notice Return the record at the given index within the asset's
    ///         chronological history.
    /// @dev STRICT: reverts IndexOutOfBounds if index is past the
    ///      history length.
    function getAssessment(bytes32 assetId, uint256 index) external view returns (AnchorRecord memory) {
        uint256[] storage ids = _byAsset[assetId];
        if (index >= ids.length) revert IndexOutOfBounds(assetId, index);
        return _records[ids[index]];
    }

    /// @notice Return the snapshot state of the latest record for the
    ///         (assetId, lenderId) pair, evaluated against atTimestamp.
    /// @dev SNAPSHOT semantics. Does NOT perform historical time-travel
    ///      search; always evaluates the most recent record for the
    ///      pair.
    ///
    ///      State model (approved MVP-03A semantic extension):
    ///        no record                              -> UNKNOWN
    ///        atTimestamp < record.performedAt       -> UNKNOWN
    ///        performedAt <= atTimestamp <= validUntil -> ACTIVE
    ///        atTimestamp > record.validUntil        -> EXPIRED
    function state(bytes32 assetId, uint32 lenderId, uint64 atTimestamp) external view returns (State) {
        uint256[] storage ids = _byAssetLender[assetId][lenderId];
        uint256 n = ids.length;
        if (n == 0) return State.UNKNOWN;

        AnchorRecord storage record = _records[ids[n - 1]];
        if (atTimestamp < record.performedAt) return State.UNKNOWN;
        if (atTimestamp <= record.validUntil) return State.ACTIVE;
        return State.EXPIRED;
    }

    /// @notice Total number of records ever anchored. Non-reverting.
    ///         Equals _nextAnchorId - 1. Returns 0 before any write.
    function totalAnchors() external view returns (uint256) {
        return _nextAnchorId - 1;
    }

    // ─── Explicitly absent ─────────────────────────────────────────

    // NO receive() external payable
    // NO fallback() external payable
    // NO withdraw / recover / rescue functions
    // NO delegatecall
    // NO selfdestruct
    // NO financial calculations (eligibleValue, creditCapacity)
    // NO runtime policyHash verification against LenderPolicyRegistry
}
