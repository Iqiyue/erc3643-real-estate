// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ComplianceModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../token/RealEstateToken.sol";

/**
 * @title CountryRestrictModule
 * @dev 国家限制模块,管理允许/禁止的国家列表
 */
contract CountryRestrictModule is ComplianceModule, Ownable {
    address public compliance;
    bool public isWhitelistMode;

    mapping(uint16 => bool) public whitelistedCountries;
    mapping(uint16 => bool) public blacklistedCountries;
    uint16[] private trackedWhitelistCountries;
    uint16[] private trackedBlacklistCountries;
    mapping(uint16 => bool) private isWhitelistCountryTracked;
    mapping(uint16 => bool) private isBlacklistCountryTracked;

    // HIGH-4 修复: 分批模式切换
    struct ModeSwitchState {
        bool inProgress;
        bool targetMode; // true = whitelist, false = blacklist
        uint256 processedIndex;
    }
    ModeSwitchState public modeSwitchState;

    event CountryWhitelisted(uint16 indexed country);
    event CountryUnwhitelisted(uint16 indexed country);
    event CountryBlacklisted(uint16 indexed country);
    event CountryUnblacklisted(uint16 indexed country);
    event ModeChanged(bool isWhitelistMode);

    constructor(bool _isWhitelistMode) Ownable(msg.sender) {
        isWhitelistMode = _isWhitelistMode;
    }

    function moduleCheck(
        address _from,
        address _to,
        uint256 /* _value */,
        address _compliance
    ) external view override returns (bool) {
        if (_from == address(0)) {
            return _checkCountry(_to, _compliance);
        }
        if (_to == address(0)) {
            return true;
        }
        return _checkCountry(_from, _compliance) && _checkCountry(_to, _compliance);
    }

    function moduleTransferAction(
        address,
        address,
        uint256,
        address
    ) external pure override {
        // No state mutation required for this module after transfer.
    }

    function _checkCountry(address _userAddress, address _complianceAddr) internal view returns (bool) {
        ModularCompliance complianceContract = ModularCompliance(_complianceAddr);
        RealEstateToken token = RealEstateToken(complianceContract.tokenBound());
        uint16 country = token.identityRegistry().investorCountry(_userAddress);

        if (isWhitelistMode) {
            return whitelistedCountries[country];
        } else {
            return !blacklistedCountries[country];
        }
    }

    function addCountryToWhitelist(uint16 _country) external onlyOwner {
        require(isWhitelistMode, "Not in whitelist mode");
        whitelistedCountries[_country] = true;
        if (!isWhitelistCountryTracked[_country]) {
            isWhitelistCountryTracked[_country] = true;
            trackedWhitelistCountries.push(_country);
        }
        emit CountryWhitelisted(_country);
    }

    function removeCountryFromWhitelist(uint16 _country) external onlyOwner {
        require(isWhitelistMode, "Not in whitelist mode");
        whitelistedCountries[_country] = false;
        emit CountryUnwhitelisted(_country);
    }

    function addCountryToBlacklist(uint16 _country) external onlyOwner {
        require(!isWhitelistMode, "Not in blacklist mode");
        blacklistedCountries[_country] = true;
        if (!isBlacklistCountryTracked[_country]) {
            isBlacklistCountryTracked[_country] = true;
            trackedBlacklistCountries.push(_country);
        }
        emit CountryBlacklisted(_country);
    }

    function removeCountryFromBlacklist(uint16 _country) external onlyOwner {
        require(!isWhitelistMode, "Not in blacklist mode");
        blacklistedCountries[_country] = false;
        emit CountryUnblacklisted(_country);
    }

    /**
     * @notice 开始模式切换 (分批处理)
     * @param _isWhitelistMode 目标模式
     */
    function startModeSwitch(bool _isWhitelistMode) external onlyOwner {
        require(!modeSwitchState.inProgress, "Switch already in progress");
        require(isWhitelistMode != _isWhitelistMode, "Already in target mode");

        modeSwitchState = ModeSwitchState({
            inProgress: true,
            targetMode: _isWhitelistMode,
            processedIndex: 0
        });

        emit ModeChanged(_isWhitelistMode);
    }

    /**
     * @notice 继续模式切换 (分批处理)
     * @param _batchSize 本次处理的数量
     */
    function continueModeSwitch(uint256 _batchSize) external onlyOwner {
        require(modeSwitchState.inProgress, "No switch in progress");

        uint256 startIndex = modeSwitchState.processedIndex;
        uint256 endIndex;

        if (modeSwitchState.targetMode) {
            // 切换到白名单模式: 清理黑名单
            endIndex = startIndex + _batchSize;
            if (endIndex > trackedBlacklistCountries.length) {
                endIndex = trackedBlacklistCountries.length;
            }

            for (uint256 i = startIndex; i < endIndex; i++) {
                blacklistedCountries[trackedBlacklistCountries[i]] = false;
            }

            if (endIndex >= trackedBlacklistCountries.length) {
                // 完成切换
                isWhitelistMode = true;
                delete modeSwitchState;
            } else {
                modeSwitchState.processedIndex = endIndex;
            }
        } else {
            // 切换到黑名单模式: 清理白名单
            endIndex = startIndex + _batchSize;
            if (endIndex > trackedWhitelistCountries.length) {
                endIndex = trackedWhitelistCountries.length;
            }

            for (uint256 i = startIndex; i < endIndex; i++) {
                whitelistedCountries[trackedWhitelistCountries[i]] = false;
            }

            if (endIndex >= trackedWhitelistCountries.length) {
                // 完成切换
                isWhitelistMode = false;
                delete modeSwitchState;
            } else {
                modeSwitchState.processedIndex = endIndex;
            }
        }
    }

    /**
     * @notice 取消模式切换
     */
    function cancelModeSwitch() external onlyOwner {
        require(modeSwitchState.inProgress, "No switch in progress");
        delete modeSwitchState;
    }

    /**
     * @notice 设置模式 (小列表可以一次性切换)
     * @dev HIGH-4 修复: 添加列表大小检查,大列表必须使用分批切换
     */
    function setMode(bool _isWhitelistMode) external onlyOwner {
        if (isWhitelistMode == _isWhitelistMode) {
            emit ModeChanged(_isWhitelistMode);
            return;
        }

        // HIGH-4 修复: 如果列表过大,要求使用分批切换
        uint256 listSize = _isWhitelistMode ? trackedBlacklistCountries.length : trackedWhitelistCountries.length;
        require(listSize <= 50, "List too large, use startModeSwitch/continueModeSwitch");

        if (_isWhitelistMode) {
            for (uint256 i = 0; i < trackedBlacklistCountries.length; i++) {
                blacklistedCountries[trackedBlacklistCountries[i]] = false;
            }
        } else {
            for (uint256 i = 0; i < trackedWhitelistCountries.length; i++) {
                whitelistedCountries[trackedWhitelistCountries[i]] = false;
            }
        }

        isWhitelistMode = _isWhitelistMode;
        emit ModeChanged(_isWhitelistMode);
    }

    function name() external pure override returns (string memory) {
        return "CountryRestrictModule";
    }

    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    function bindCompliance(address _compliance) external override {
        require(msg.sender == _compliance || msg.sender == owner(), "Unauthorized binder");
        require(compliance == address(0), "Already bound");
        compliance = _compliance;
    }

    function unbindCompliance(address _compliance) external override {
        require(msg.sender == _compliance || msg.sender == owner(), "Unauthorized unbinder");
        require(compliance == _compliance, "Not bound to this compliance");
        compliance = address(0);
    }
}
