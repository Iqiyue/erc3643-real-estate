// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ClaimIssuer.sol";

/**
 * @title Identity
 * @dev 实现 ERC-734 和 ERC-735 标准的链上身份合约
 */
contract Identity {
    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes signature;
        bytes data;
        string uri;
        uint256 issuedAt;
        uint256 expiresAt;
        uint256 nonce;
    }

    mapping(bytes32 => Claim) private claims;
    mapping(uint256 => bytes32[]) private claimsByTopic;
    address public owner;
    bool public initialized;

    // DoS 防护: 限制每个 topic 的最大 claims 数量
    uint256 public constant MAX_CLAIMS_PER_TOPIC = 10;
    mapping(uint256 => uint256) public claimCountByTopic;

    // HIGH-2 修复: 受信任的 claim 签发者
    mapping(address => bool) public trustedIssuers;

    event ClaimAdded(bytes32 indexed claimId, uint256 indexed topic, uint256 scheme, address indexed issuer, bytes signature, bytes data, string uri, uint256 nonce);
    event ClaimRemoved(bytes32 indexed claimId, uint256 indexed topic, uint256 scheme, address indexed issuer);
    event Initialized(address indexed owner);
    event TrustedIssuerAdded(address indexed issuer);
    event TrustedIssuerRemoved(address indexed issuer);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyInitialized() {
        require(initialized, "Identity: not initialized");
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "Identity: caller is not the owner");
    }

    constructor(address _owner) {
        owner = _owner;
        initialized = true;
        emit Initialized(_owner);
    }

    function initialize(address _owner) external {
        require(!initialized, "Identity: already initialized");
        require(_owner != address(0), "Identity: invalid owner");
        owner = _owner;
        initialized = true;
        emit Initialized(_owner);
    }

    function addClaim(
        uint256 _topic,
        uint256 _scheme,
        address _issuer,
        bytes memory _signature,
        bytes memory _data,
        string memory _uri,
        uint256 _expiresAt,
        uint256 _nonce
    ) public onlyOwner onlyInitialized returns (bytes32 claimId) {
        // HIGH-2 修复: 验证签发者是否受信任
        require(trustedIssuers[_issuer], "Identity: issuer not trusted");

        // Use the same identity-scoped claim id semantics as ClaimIssuer.
        claimId = ClaimIssuer(_issuer).getClaimId(address(this), _topic, _data, _expiresAt, _nonce);

        require(claims[claimId].issuer == address(0), "Identity: claim exists");
        require(claimCountByTopic[_topic] < MAX_CLAIMS_PER_TOPIC, "Identity: too many claims for this topic");

        // Strict validation: the trusted issuer must recognize the claim as valid
        // for this identity before it can be stored.
        require(
            ClaimIssuer(_issuer).isClaimValid(address(this), _topic, _data, _signature, _expiresAt, _nonce),
            "Identity: invalid signature"
        );

        claims[claimId] = Claim({
            topic: _topic,
            scheme: _scheme,
            issuer: _issuer,
            signature: _signature,
            data: _data,
            uri: _uri,
            issuedAt: block.timestamp,
            expiresAt: _expiresAt,
            nonce: _nonce
        });

        bool found = false;
        bytes32[] storage topicClaims = claimsByTopic[_topic];
        for (uint256 i = 0; i < topicClaims.length; i++) {
            if (topicClaims[i] == claimId) {
                found = true;
                break;
            }
        }
        if (!found) {
            claimsByTopic[_topic].push(claimId);
            claimCountByTopic[_topic]++;
        }

        emit ClaimAdded(claimId, _topic, _scheme, _issuer, _signature, _data, _uri, _nonce);
    }

    function removeClaim(bytes32 _claimId) public onlyOwner onlyInitialized returns (bool) {
        Claim memory claim = claims[_claimId];
        require(claim.issuer != address(0), "Identity: claim does not exist");

        bytes32[] storage topicClaims = claimsByTopic[claim.topic];
        for (uint256 i = 0; i < topicClaims.length; i++) {
            if (topicClaims[i] == _claimId) {
                topicClaims[i] = topicClaims[topicClaims.length - 1];
                topicClaims.pop();
                claimCountByTopic[claim.topic]--;
                break;
            }
        }

        emit ClaimRemoved(_claimId, claim.topic, claim.scheme, claim.issuer);
        delete claims[_claimId];
        return true;
    }

    function getClaimWithNonce(bytes32 _claimId) public view returns (
        uint256 topic, uint256 scheme, address issuer, bytes memory signature,
        bytes memory data, string memory uri, uint256 issuedAt, uint256 expiresAt, uint256 nonce
    ) {
        Claim memory claim = claims[_claimId];
        return (claim.topic, claim.scheme, claim.issuer, claim.signature, claim.data, claim.uri, claim.issuedAt, claim.expiresAt, claim.nonce);
    }

    function getClaimIdsByTopic(uint256 _topic) public view returns (bytes32[] memory) {
        return claimsByTopic[_topic];
    }

    /**
     * @notice 添加受信任的 claim 签发者
     * @param _issuer 签发者地址
     */
    function authorizeClaimIssuer(address _issuer) external onlyOwner onlyInitialized {
        require(_issuer != address(0), "Identity: invalid issuer");
        require(!trustedIssuers[_issuer], "Identity: issuer already trusted");
        trustedIssuers[_issuer] = true;
        emit TrustedIssuerAdded(_issuer);
    }

    /**
     * @notice 移除受信任的 claim 签发者
     * @param _issuer 签发者地址
     */
    function revokeClaimIssuerAuthorization(address _issuer) external onlyOwner onlyInitialized {
        require(trustedIssuers[_issuer], "Identity: issuer not trusted");
        trustedIssuers[_issuer] = false;
        emit TrustedIssuerRemoved(_issuer);
    }

    /**
     * @notice 检查签发者是否受信任
     * @param _issuer 签发者地址
     */
    function isAuthorizedClaimIssuer(address _issuer) external view returns (bool) {
        return trustedIssuers[_issuer];
    }
}
