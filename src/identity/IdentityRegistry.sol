// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./IdentityRegistryStorage.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./Identity.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ClaimIssuer.sol";

contract IdentityRegistry is Ownable {
    IdentityRegistryStorage public identityStorage;
    mapping(address => bool) public trustedIssuers;
    address[] public trustedIssuersList;
    uint256[] public claimTopicsRequired;

    event IdentityRegistered(address indexed investorAddress, address indexed identity);
    event IdentityRemoved(address indexed investorAddress, address indexed identity);
    event TrustedIssuerAdded(address indexed trustedIssuer);

    constructor(address _identityStorage, address[] memory _trustedIssuers, uint256[] memory _claimTopics) Ownable(msg.sender) {
        identityStorage = IdentityRegistryStorage(_identityStorage);
        for (uint256 i = 0; i < _trustedIssuers.length; i++) {
            trustedIssuers[_trustedIssuers[i]] = true;
            trustedIssuersList.push(_trustedIssuers[i]);
        }
        claimTopicsRequired = _claimTopics;
    }

    function registerIdentity(address _userAddress, address _identity, uint16 _country) external onlyOwner {
        require(identityStorage.storedIdentity(_userAddress) == address(0), "Already registered");

        // 先存储身份
        identityStorage.addIdentityToStorage(_userAddress, _identity, _country);

        // 然后验证身份是否有效
        require(isVerified(_userAddress), "Not verified");

        emit IdentityRegistered(_userAddress, _identity);
    }

    function deleteIdentity(address _userAddress) external onlyOwner {
        address identityAddr = identityStorage.storedIdentity(_userAddress);
        require(identityAddr != address(0), "Not registered");
        identityStorage.removeIdentityFromStorage(_userAddress);
        emit IdentityRemoved(_userAddress, identityAddr);
    }

    function isVerified(address _userAddress) public view returns (bool) {
        address identityAddr = identityStorage.storedIdentity(_userAddress);
        if (identityAddr == address(0)) return false;

        Identity identityContract = Identity(identityAddr);

        for (uint256 i = 0; i < claimTopicsRequired.length; i++) {
            uint256 topic = claimTopicsRequired[i];
            bytes32[] memory claimIds = identityContract.getClaimIdsByTopic(topic);

            bool topicVerified = false;
            for (uint256 j = 0; j < claimIds.length; j++) {
                (,, address issuer, bytes memory signature, bytes memory data,, , uint256 expiresAt, uint256 nonce) =
                    identityContract.getClaimWithNonce(claimIds[j]);

                if (!trustedIssuers[issuer]) continue;

                ClaimIssuer issuerContract = ClaimIssuer(issuer);
                if (issuerContract.isClaimValid(identityAddr, topic, data, signature, expiresAt, nonce)) {
                    topicVerified = true;
                    break;
                }
            }

            if (!topicVerified) return false;
        }

        return true;
    }

    /**
     * @notice 批量注册投资者身份 (已废弃,请使用 batchRegisterAndVerifyIdentity)
     * @dev 此函数已被标记为废弃,因为它绕过了 KYC 验证
     *      为了向后兼容保留,但会在注册后验证每个身份
     * @param _userAddresses 投资者地址数组
     * @param _identities 身份合约地址数组
     * @param _countries 国家代码数组
     */
    function batchRegisterIdentity(
        address[] calldata _userAddresses,
        address[] calldata _identities,
        uint16[] calldata _countries
    ) external onlyOwner {
        _batchRegisterAndVerifyIdentity(_userAddresses, _identities, _countries);
    }

    /**
     * @notice 批量注册并验证身份
     * @dev 与 batchRegisterIdentity 不同,此函数会验证每个身份是否有有效的 claims
     * @param _userAddresses 投资者地址数组
     * @param _identities 身份合约地址数组
     * @param _countries 国家代码数组
     */
    function batchRegisterAndVerifyIdentity(
        address[] calldata _userAddresses,
        address[] calldata _identities,
        uint16[] calldata _countries
    ) external onlyOwner {
        _batchRegisterAndVerifyIdentity(_userAddresses, _identities, _countries);
    }

    function _batchRegisterAndVerifyIdentity(
        address[] calldata _userAddresses,
        address[] calldata _identities,
        uint16[] calldata _countries
    ) internal {
        require(
            _userAddresses.length == _identities.length && _userAddresses.length == _countries.length,
            "Array length mismatch"
        );

        // 第一阶段: 预验证所有输入
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            // 跳过已注册的地址
            if (identityStorage.storedIdentity(_userAddresses[i]) != address(0)) {
                continue;
            }

            // 验证身份合约地址有效
            require(_identities[i] != address(0), "Invalid identity address");
            require(_identities[i].code.length > 0, "Identity must be a contract");
            require(_userAddresses[i] != address(0), "Invalid user address");
        }

        // 第二阶段: 批量注册
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            if (identityStorage.storedIdentity(_userAddresses[i]) != address(0)) {
                continue; // 跳过已注册的
            }

            // 存储身份
            identityStorage.addIdentityToStorage(_userAddresses[i], _identities[i], _countries[i]);

            // 第三阶段: 验证身份是否有有效的 claims
            require(isVerified(_userAddresses[i]), "Identity not verified");

            emit IdentityRegistered(_userAddresses[i], _identities[i]);
        }
    }

    function identity(address _userAddress) external view returns (address) {
        return identityStorage.storedIdentity(_userAddress);
    }

    function investorCountry(address _userAddress) external view returns (uint16) {
        return identityStorage.storedInvestorCountry(_userAddress);
    }

    function addTrustedIssuer(address _trustedIssuer) external onlyOwner {
        require(!trustedIssuers[_trustedIssuer], "Already trusted");
        trustedIssuers[_trustedIssuer] = true;
        trustedIssuersList.push(_trustedIssuer);
        emit TrustedIssuerAdded(_trustedIssuer);
    }
}
