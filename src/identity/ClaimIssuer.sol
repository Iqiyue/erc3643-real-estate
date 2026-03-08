// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title ClaimIssuer
 * @dev 受信任的 KYC 服务商
 */
contract ClaimIssuer is Ownable, EIP712 {
    using ECDSA for bytes32;
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address identity,uint256 topic,bytes32 dataHash,uint256 expiresAt,uint256 nonce)");

    mapping(bytes32 => bool) public revokedClaims;
    mapping(address => mapping(uint256 => bool)) public usedNonces; // identity => nonce => used

    event ClaimRevoked(bytes32 indexed claimId, address indexed identity, uint256 indexed topic);
    event ClaimRestored(bytes32 indexed claimId, address indexed identity, uint256 indexed topic);
    event NonceUsed(address indexed identity, uint256 indexed nonce);

    constructor() Ownable(msg.sender) EIP712("ClaimIssuer", "1") {}

    function getSignedClaim(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        uint256 _expiresAt,
        uint256 _nonce
    ) public view returns (bytes32) {
        return _hashClaim(_identity, _topic, _data, _expiresAt, _nonce);
    }

    function getSignedClaim(address _identity, uint256 _topic, bytes memory _data) public view returns (bytes32) {
        // Backward-compatible helper (legacy tests/flows).
        return _hashClaim(_identity, _topic, _data, 0, 0);
    }

    function getClaimId(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        uint256 _expiresAt,
        uint256 _nonce
    ) public pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(_identity, _topic, keccak256(_data), _expiresAt, _nonce));
    }

    function getClaimId(address _identity, uint256 _topic, bytes memory _data) public pure returns (bytes32) {
        return getClaimId(_identity, _topic, _data, 0, 0);
    }

    function isClaimValid(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        bytes memory _signature,
        uint256 _expiresAt,
        uint256 _nonce
    ) public view returns (bool) {
        bytes32 signedHash = _hashClaim(_identity, _topic, _data, _expiresAt, _nonce);
        address signer = signedHash.recover(_signature);
        bytes32 claimId = getClaimId(_identity, _topic, _data, _expiresAt, _nonce);
        if (_expiresAt > 0 && _expiresAt < block.timestamp) return false;
        if (_nonce > 0 && usedNonces[_identity][_nonce]) return false; // Check nonce replay
        return signer == owner() && !revokedClaims[claimId];
    }

    function isClaimValid(address _identity, uint256 _topic, bytes memory _data, bytes memory _signature) public view returns (bool) {
        return isClaimValid(_identity, _topic, _data, _signature, 0, 0);
    }

    function revokeClaim(bytes32 _claimId) public onlyOwner {
        revokedClaims[_claimId] = true;
        emit ClaimRevoked(_claimId, address(0), 0);
    }

    function revokeClaim(address _identity, uint256 _topic, bytes memory _data) public onlyOwner {
        bytes32 claimId = getClaimId(_identity, _topic, _data, 0, 0);
        revokedClaims[claimId] = true;
        emit ClaimRevoked(claimId, _identity, _topic);
    }

    function revokeClaim(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        uint256 _expiresAt,
        uint256 _nonce
    ) public onlyOwner {
        bytes32 claimId = getClaimId(_identity, _topic, _data, _expiresAt, _nonce);
        revokedClaims[claimId] = true;
        emit ClaimRevoked(claimId, _identity, _topic);
    }

    function restoreClaim(bytes32 _claimId) public onlyOwner {
        revokedClaims[_claimId] = false;
        emit ClaimRestored(_claimId, address(0), 0);
    }

    function restoreClaim(address _identity, uint256 _topic, bytes memory _data) public onlyOwner {
        bytes32 claimId = getClaimId(_identity, _topic, _data, 0, 0);
        revokedClaims[claimId] = false;
        emit ClaimRestored(claimId, _identity, _topic);
    }

    function restoreClaim(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        uint256 _expiresAt,
        uint256 _nonce
    ) public onlyOwner {
        bytes32 claimId = getClaimId(_identity, _topic, _data, _expiresAt, _nonce);
        revokedClaims[claimId] = false;
        emit ClaimRestored(claimId, _identity, _topic);
    }

    function isClaimRevoked(bytes32 _claimId) public view returns (bool) {
        return revokedClaims[_claimId];
    }

    /**
     * @dev Mark nonce as used to prevent replay attacks
     * @param _identity Identity address
     * @param _nonce Nonce to mark as used
     */
    function markNonceUsed(address _identity, uint256 _nonce) external {
        require(_nonce > 0, "Nonce must be positive");
        require(!usedNonces[_identity][_nonce], "Nonce already used");
        usedNonces[_identity][_nonce] = true;
        emit NonceUsed(_identity, _nonce);
    }

    function _hashClaim(
        address _identity,
        uint256 _topic,
        bytes memory _data,
        uint256 _expiresAt,
        uint256 _nonce
    ) internal view returns (bytes32) {
        bytes32 dataHash;
        assembly {
            dataHash := keccak256(add(_data, 0x20), mload(_data))
        }
        bytes32 claimTypeHash = CLAIM_TYPEHASH;
        bytes32 structHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, claimTypeHash)
            mstore(add(ptr, 0x20), _identity)
            mstore(add(ptr, 0x40), _topic)
            mstore(add(ptr, 0x60), dataHash)
            mstore(add(ptr, 0x80), _expiresAt)
            mstore(add(ptr, 0xa0), _nonce)
            structHash := keccak256(ptr, 0xc0)
        }
        return _hashTypedDataV4(structHash);
    }
}
