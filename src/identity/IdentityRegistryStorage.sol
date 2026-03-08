// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";

contract IdentityRegistryStorage is Ownable {
    mapping(address => address) private identities;
    mapping(address => uint16) private investorCountries;
    address[] private investorAddresses;
    mapping(address => uint256) private investorIndexPlusOne;
    address public identityRegistry;

    event IdentityStored(address indexed investorAddress, address indexed identity);
    event IdentityRemoved(address indexed investorAddress, address indexed identity);
    event CountryModified(address indexed investorAddress, uint16 indexed country);
    event IdentityRegistryBound(address indexed identityRegistry);
    event IdentityRegistryUnbound(address indexed identityRegistry);

    modifier onlyIdentityRegistry() {
        _onlyIdentityRegistry();
        _;
    }

    function _onlyIdentityRegistry() internal view {
        require(msg.sender == identityRegistry, "Only identity registry");
    }

    constructor() Ownable(msg.sender) {}

    /**
     * @dev 绑定 IdentityRegistry (MEDIUM-7 修复: 添加验证)
     * @param _identityRegistry IdentityRegistry 地址
     */
    function bindIdentityRegistry(address _identityRegistry) external onlyOwner {
        require(_identityRegistry != address(0), "Invalid registry address");
        require(identityRegistry == address(0), "Already bound to a registry");
        identityRegistry = _identityRegistry;
        emit IdentityRegistryBound(_identityRegistry);
    }

    /**
     * @dev 解绑 IdentityRegistry (MEDIUM-7 修复: 新增)
     */
    function unbindIdentityRegistry() external onlyOwner {
        require(identityRegistry != address(0), "No registry bound");
        address oldRegistry = identityRegistry;
        identityRegistry = address(0);
        emit IdentityRegistryUnbound(oldRegistry);
    }

    function addIdentityToStorage(address _userAddress, address _identity, uint16 _country) external onlyIdentityRegistry {
        require(identities[_userAddress] == address(0), "Identity exists");
        identities[_userAddress] = _identity;
        investorCountries[_userAddress] = _country;
        investorIndexPlusOne[_userAddress] = investorAddresses.length + 1;
        investorAddresses.push(_userAddress);
        emit IdentityStored(_userAddress, _identity);
        emit CountryModified(_userAddress, _country);
    }

    function modifyStoredIdentity(address _userAddress, address _identity) external onlyIdentityRegistry {
        require(identities[_userAddress] != address(0), "Identity not found");
        address oldIdentity = identities[_userAddress];
        identities[_userAddress] = _identity;
        emit IdentityRemoved(_userAddress, oldIdentity);
        emit IdentityStored(_userAddress, _identity);
    }

    function modifyStoredInvestorCountry(address _userAddress, uint16 _country) external onlyIdentityRegistry {
        require(identities[_userAddress] != address(0), "Identity not found");
        investorCountries[_userAddress] = _country;
        emit CountryModified(_userAddress, _country);
    }

    function removeIdentityFromStorage(address _userAddress) external onlyIdentityRegistry {
        require(identities[_userAddress] != address(0), "Identity not found");
        address identity = identities[_userAddress];
        delete identities[_userAddress];
        delete investorCountries[_userAddress];

        uint256 indexPlusOne = investorIndexPlusOne[_userAddress];
        if (indexPlusOne != 0) {
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = investorAddresses.length - 1;

            if (index != lastIndex) {
                address lastInvestor = investorAddresses[lastIndex];
                investorAddresses[index] = lastInvestor;
                investorIndexPlusOne[lastInvestor] = index + 1;
            }

            investorAddresses.pop();
            delete investorIndexPlusOne[_userAddress];
        }
        emit IdentityRemoved(_userAddress, identity);
    }

    function storedIdentity(address _userAddress) external view returns (address) {
        return identities[_userAddress];
    }

    function storedInvestorCountry(address _userAddress) external view returns (uint16) {
        return investorCountries[_userAddress];
    }

    function getInvestorAddresses() external view returns (address[] memory) {
        return investorAddresses;
    }
}
