// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Minimal interface into LenderRegistry required by
///         LenderPolicyRegistry. Mirrors the corresponding types and
///         functions of contracts/src/LenderRegistry.sol.
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
    function lenderExists(uint256 lenderId) external view returns (bool);
    function isActive(uint256 lenderId) external view returns (bool);
    function getLender(uint256 lenderId) external view returns (Lender memory);
}

/// @title LenderPolicyRegistry
/// @notice Stores lender-defined collateral policies for the LindFi
///         protocol. Policies are append-only, versioned, and
///         attributable to a specific lender. On-chain records commit
///         to a policy hash; complete policy documents are JSON stored
///         off-chain in R2. Governance-controlled. Holds no funds. No
///         receive/fallback.
/// @dev Follows MVP03A_GOVERNANCE_AMENDMENT_01:
///        - governance supplied at construction (rejects address(0))
///        - two-step transfer via transferGovernance + acceptGovernance
///        - governance() / pendingGovernance() satisfied by public storage
///      Constructor verifies LenderRegistry.governance() == _governance.
///      Deployment follows DEPLOY_GUARDRAIL_SPEC.
contract LenderPolicyRegistry {
    // ─── Types ─────────────────────────────────────────────────────

    struct Policy {
        uint256 policyId;
        uint256 lenderId;
        bytes32 assetClass;
        bytes32 policyHash;
        uint256 effectiveFrom;
        uint256 effectiveUntil;
        bool active;
        address publishedBy;
        uint256 recordedAt;
    }

    // ─── Storage ───────────────────────────────────────────────────

    /// @notice Current governance address. Two-step transfer authority.
    address public governance;

    /// @notice Address awaiting acceptGovernance() to become the new
    ///         governance. Zero when no transfer is pending.
    address public pendingGovernance;

    /// @notice The LenderRegistry contract this registry composes with.
    /// @dev Immutable: set at construction, never changed. Frozen
    ///      cross-registry pairing prevents governance from repointing
    ///      to a different LenderRegistry post-deploy.
    address public immutable lenderRegistry;

    /// @dev Next policy id to assign. Monotonic, never decremented.
    ///      Explicitly starts at 1 so that policy id 0 remains the
    ///      "unassigned" sentinel.
    uint256 private _nextPolicyId = 1;

    /// @dev Full policy records by policy id.
    mapping(uint256 => Policy) private _policies;

    /// @notice Reverse index: (lenderId, assetClass) → active policyId.
    /// @dev Returns 0 when no active policy exists for the pair.
    ///      Cleared by explicit deprecatePolicy. Replaced (not cleared)
    ///      by auto-supersession during publishPolicy.
    mapping(uint256 => mapping(bytes32 => uint256)) public activePolicyOf;

    // ─── Events ────────────────────────────────────────────────────

    event PolicyPublished(
        uint256 indexed policyId,
        uint256 indexed lenderId,
        bytes32 indexed assetClass,
        bytes32 policyHash,
        uint256 effectiveFrom,
        uint256 effectiveUntil,
        address publishedBy
    );

    event PolicySuperseded(
        uint256 indexed previousPolicyId, uint256 indexed newPolicyId, uint256 indexed lenderId, bytes32 assetClass
    );

    event PolicyDeprecated(uint256 indexed policyId);

    event PolicyValidityUpdated(uint256 indexed policyId, uint256 newEffectiveUntil);

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    // ─── Custom errors ─────────────────────────────────────────────

    // Governance / construction
    error ZeroGovernance();
    error ZeroLenderRegistry();
    error LenderRegistryGovernanceMismatch(address actual, address expected);
    error NotGovernance();
    error NotPendingGovernance();

    // Lender-side authorization
    error NotAuthorized();
    error LenderDoesNotExist(uint256 lenderId);
    error LenderNotActive(uint256 lenderId);
    error LenderNotVerified(uint256 lenderId);

    // Policy validation
    error ZeroAssetClass();
    error ZeroPolicyHash();
    error InvalidValidityWindow(uint256 effectiveFrom, uint256 effectiveUntil);

    // Policy lifecycle
    error PolicyDoesNotExist(uint256 policyId);
    error PolicyNotActive(uint256 policyId);
    error PolicyAlreadyInactive(uint256 policyId);

    // ─── Modifiers ─────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────

    /// @param _governance Expected canonical governance for the target
    ///        network. Must be non-zero. Passed by the deploy script
    ///        from Constants.expectedSafeFor(block.chainid).
    /// @param _lenderRegistry Address of the previously deployed
    ///        LenderRegistry contract. Must be non-zero. Its
    ///        governance() must equal _governance (cross-registry
    ///        pairing guardrail).
    constructor(address _governance, address _lenderRegistry) {
        if (_governance == address(0)) revert ZeroGovernance();
        if (_lenderRegistry == address(0)) revert ZeroLenderRegistry();

        address registryGovernance = ILenderRegistry(_lenderRegistry).governance();
        if (registryGovernance != _governance) {
            revert LenderRegistryGovernanceMismatch(registryGovernance, _governance);
        }

        governance = _governance;
        lenderRegistry = _lenderRegistry;
    }

    // ─── Actions ───────────────────────────────────────────────────

    /// @notice Publish a new policy version for (lenderId, assetClass).
    ///         Auto-deprecates the previous active policy for that pair
    ///         (if any). Preserves historical records.
    /// @dev Authorization: governance OR the current lender signer in
    ///      LenderRegistry. In both paths the lender must exist, be
    ///      active, and have KybStatus == VERIFIED. Governance does NOT
    ///      bypass the active/VERIFIED requirements.
    function publishPolicy(
        uint256 lenderId,
        bytes32 assetClass,
        bytes32 policyHash,
        uint256 effectiveFrom,
        uint256 effectiveUntil
    ) external returns (uint256 policyId) {
        // 1. Authorization checks
        ILenderRegistry.Lender memory lender = _loadLenderForPublish(lenderId);

        if (msg.sender != governance) {
            if (msg.sender != lender.signerAddress) revert NotAuthorized();
        }

        if (!lender.active) revert LenderNotActive(lenderId);
        if (lender.kybStatus != ILenderRegistry.KybStatus.VERIFIED) {
            revert LenderNotVerified(lenderId);
        }

        // 2. Frozen validation rules
        if (assetClass == bytes32(0)) revert ZeroAssetClass();
        if (policyHash == bytes32(0)) revert ZeroPolicyHash();
        if (effectiveUntil <= effectiveFrom) {
            revert InvalidValidityWindow(effectiveFrom, effectiveUntil);
        }

        // 3. Read previous active policyId (do not mutate yet)
        uint256 previousId = activePolicyOf[lenderId][assetClass];

        // 4. Assign new policyId
        policyId = _nextPolicyId;
        _nextPolicyId = policyId + 1;

        // 5. Mark previous policy inactive (if any)
        if (previousId != 0) {
            _policies[previousId].active = false;
        }

        // 6. Store new record
        _policies[policyId] = Policy({
            policyId: policyId,
            lenderId: lenderId,
            assetClass: assetClass,
            policyHash: policyHash,
            effectiveFrom: effectiveFrom,
            effectiveUntil: effectiveUntil,
            active: true,
            publishedBy: msg.sender,
            recordedAt: block.timestamp
        });

        // 7. Update reverse index
        activePolicyOf[lenderId][assetClass] = policyId;

        // 8. Emit PolicyPublished
        emit PolicyPublished(policyId, lenderId, assetClass, policyHash, effectiveFrom, effectiveUntil, msg.sender);

        // 9. If auto-supersession occurred, emit PolicySuperseded
        if (previousId != 0) {
            emit PolicySuperseded(previousId, policyId, lenderId, assetClass);
        }
    }

    /// @dev Load a lender for publish/update paths. Reverts with
    ///      LenderDoesNotExist on the governance path if lenderId is
    ///      unknown; on the signer path the underlying LenderRegistry
    ///      revert bubbles up.
    function _loadLenderForPublish(uint256 lenderId) private view returns (ILenderRegistry.Lender memory lender) {
        if (msg.sender == governance) {
            if (!ILenderRegistry(lenderRegistry).lenderExists(lenderId)) {
                revert LenderDoesNotExist(lenderId);
            }
        }
        lender = ILenderRegistry(lenderRegistry).getLender(lenderId);
    }

    /// @notice Deprecate an active policy. Preserves the record;
    ///         clears the reverse index.
    /// @dev Weaker auth than publish/update: no active/KYB requirement.
    ///      A deactivated or non-VERIFIED lender's current signer may
    ///      still deprecate. Governance may deprecate for any policy.
    function deprecatePolicy(uint256 policyId) external {
        Policy storage p = _policies[policyId];
        if (p.policyId == 0) revert PolicyDoesNotExist(policyId);
        if (!p.active) revert PolicyAlreadyInactive(policyId);

        if (msg.sender != governance) {
            ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(p.lenderId);
            if (msg.sender != lender.signerAddress) revert NotAuthorized();
        }

        p.active = false;
        activePolicyOf[p.lenderId][p.assetClass] = 0;

        emit PolicyDeprecated(policyId);
    }

    /// @notice Update the effectiveUntil of an active policy.
    /// @dev Same auth model as publishPolicy: governance OR current
    ///      lender signer, and lender must be active + VERIFIED.
    ///      policyHash and effectiveFrom are never modified.
    ///      newEffectiveUntil may be shorter or longer than the current
    ///      effectiveUntil; the only constraint is
    ///      newEffectiveUntil > effectiveFrom.
    function updatePolicyValidity(uint256 policyId, uint256 newEffectiveUntil) external {
        Policy storage p = _policies[policyId];
        if (p.policyId == 0) revert PolicyDoesNotExist(policyId);
        if (!p.active) revert PolicyNotActive(policyId);

        ILenderRegistry.Lender memory lender = ILenderRegistry(lenderRegistry).getLender(p.lenderId);

        if (msg.sender != governance) {
            if (msg.sender != lender.signerAddress) revert NotAuthorized();
        }

        if (!lender.active) revert LenderNotActive(p.lenderId);
        if (lender.kybStatus != ILenderRegistry.KybStatus.VERIFIED) {
            revert LenderNotVerified(p.lenderId);
        }

        if (newEffectiveUntil <= p.effectiveFrom) {
            revert InvalidValidityWindow(p.effectiveFrom, newEffectiveUntil);
        }

        p.effectiveUntil = newEffectiveUntil;

        emit PolicyValidityUpdated(policyId, newEffectiveUntil);
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

    /// @notice Return the full policy record for a given id.
    /// @dev Strict: reverts if the policy does not exist. Use
    ///      policyExists / isPolicyActive for non-reverting queries.
    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        Policy storage p = _policies[policyId];
        if (p.policyId == 0) revert PolicyDoesNotExist(policyId);
        return p;
    }

    /// @notice Non-reverting existence check.
    function policyExists(uint256 policyId) external view returns (bool) {
        return _policies[policyId].policyId != 0;
    }

    /// @notice Non-reverting active-status check. Returns false for
    ///         unknown or deprecated policies.
    function isPolicyActive(uint256 policyId) external view returns (bool) {
        return _policies[policyId].active;
    }

    /// @notice Convenience view over the activePolicyOf mapping.
    function getActivePolicyId(uint256 lenderId, bytes32 assetClass) external view returns (uint256) {
        return activePolicyOf[lenderId][assetClass];
    }

    /// @notice Total number of policies published so far (including
    ///         deprecated). Equals _nextPolicyId - 1.
    function totalPolicies() external view returns (uint256) {
        return _nextPolicyId - 1;
    }

    // ─── Explicitly absent ─────────────────────────────────────────

    // NO receive() external payable
    // NO fallback() external payable
    // NO withdraw / recover / rescue functions
    // NO delegatecall
    // NO selfdestruct
}
