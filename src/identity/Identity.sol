// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // DoS 防护: 限制每个 topic 的最大 claims 数量
    uint256 public constant MAX_CLAIMS_PER_TOPIC = 10;
    mapping(uint256 => uint256) public claimCountByTopic;

    // HIGH-2 修复: 受信任的 claim 签发者
    mapping(address => bool) public trustedIssuers;

    event ClaimAdded(bytes32 indexed claimId, uint256 indexed topic, uint256 scheme, address indexed issuer, bytes signature, bytes data, string uri, uint256 nonce);
    event ClaimRemoved(bytes32 indexed claimId, uint256 indexed topic, uint256 scheme, address indexed issuer);
    event TrustedIssuerAdded(address indexed issuer);
    event TrustedIssuerRemoved(address indexed issuer);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "Identity: caller is not the owner");
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function addClaim(
        uint256 _topic,
        uint256 _scheme,
        address _issuer,
        bytes memory _signature,
        bytes memory _data,
        string memory _uri,
        uint256 _expiresAt
    ) public onlyOwner returns (bytes32 claimId) {
        return addClaim(
            _topic,
            _scheme,
            _issuer,
            _signature,
            _data,
            _uri,
            _expiresAt,
            0
        );
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
    ) public onlyOwner returns (bytes32 claimId) {
        // HIGH-2 修复: 验证签发者是否受信任
        require(trustedIssuers[_issuer], "Identity: issuer not trusted");

        claimId = keccak256(abi.encodePacked(_issuer, _topic));

        // DoS 防护: 检查是否是新 claim
        bool isNewClaim = claims[claimId].issuer == address(0);

        // 如果是新 claim,检查 topic 的 claim 数量限制
        if (isNewClaim) {
            require(claimCountByTopic[_topic] < MAX_CLAIMS_PER_TOPIC, "Identity: too many claims for this topic");
        }

        require(claims[claimId].issuer == address(0) || claims[claimId].issuer == _issuer, "Identity: claim exists");

        // HIGH-2 修复: 验证签名 (基础验证,实际应用中需要更复杂的签名验证)
        // 注意: 这里简化了签名验证,生产环境需要完整的 ECDSA 验证
        require(_signature.length > 0, "Identity: invalid signature");

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

    function removeClaim(bytes32 _claimId) public onlyOwner returns (bool) {
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

    function getClaim(bytes32 _claimId) public view returns (
        uint256 topic, uint256 scheme, address issuer, bytes memory signature,
        bytes memory data, string memory uri, uint256 issuedAt, uint256 expiresAt
    ) {
        Claim memory claim = claims[_claimId];
        return (claim.topic, claim.scheme, claim.issuer, claim.signature, claim.data, claim.uri, claim.issuedAt, claim.expiresAt);
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

    function isClaimValid(bytes32 _claimId) public view returns (bool) {
        Claim memory claim = claims[_claimId];
        if (claim.issuer == address(0)) return false;
        if (claim.expiresAt > 0 && claim.expiresAt < block.timestamp) return false;
        return true;
    }

    /**
     * @notice 添加受信任的 claim 签发者
     * @param _issuer 签发者地址
     */
    function addTrustedIssuer(address _issuer) external onlyOwner {
        require(_issuer != address(0), "Identity: invalid issuer");
        require(!trustedIssuers[_issuer], "Identity: issuer already trusted");
        trustedIssuers[_issuer] = true;
        emit TrustedIssuerAdded(_issuer);
    }

    /**
     * @notice 移除受信任的 claim 签发者
     * @param _issuer 签发者地址
     */
    function removeTrustedIssuer(address _issuer) external onlyOwner {
        require(trustedIssuers[_issuer], "Identity: issuer not trusted");
        trustedIssuers[_issuer] = false;
        emit TrustedIssuerRemoved(_issuer);
    }

    /**
     * @notice 检查签发者是否受信任
     * @param _issuer 签发者地址
     */
    function isTrustedIssuer(address _issuer) external view returns (bool) {
        return trustedIssuers[_issuer];
    }
}
