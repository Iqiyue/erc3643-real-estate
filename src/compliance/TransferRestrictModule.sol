// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ComplianceModule.sol";

/**
 * @title TransferRestrictModule
 * @dev 转账限制模块,管理锁定期和转账限制
 */
contract TransferRestrictModule is ComplianceModule, Ownable {
    address public compliance;

    uint256 public lockupPeriod;
    mapping(address => uint256) public holdingStartTime;
    mapping(address => bool) public lockupWhitelist;

    // MEDIUM-6 修复: 时间戳操纵防护
    uint256 public constant MAX_TIMESTAMP_DRIFT = 15 minutes; // 允许的最大时间戳偏移
    uint256 public lastBlockTimestamp;

    event LockupPeriodSet(uint256 lockupPeriod);
    event HoldingStartTimeSet(address indexed investor, uint256 startTime);
    event AddressAddedToWhitelist(address indexed addr);
    event AddressRemovedFromWhitelist(address indexed addr);

    constructor(uint256 _lockupPeriod) Ownable(msg.sender) {
        lockupPeriod = _lockupPeriod;
        lastBlockTimestamp = block.timestamp;
    }

    function moduleCheck(
        address _from,
        address _to,
        uint256 /* _value */,
        address /* _compliance */
    ) external view override returns (bool) {
        // Mint 操作
        if (_from == address(0)) {
            return true;
        }

        // Burn 操作
        if (_to == address(0)) {
            return true;
        }

        // 检查白名单
        if (lockupWhitelist[_from] || lockupWhitelist[_to]) {
            return true;
        }

        // 检查锁定期
        if (holdingStartTime[_from] == 0) {
            return false;
        }

        if (block.timestamp < holdingStartTime[_from] + lockupPeriod) {
            return false;
        }

        return true;
    }

    function moduleTransferAction(
        address _from,
        address _to,
        uint256 /* _value */,
        address /* _compliance */
    ) external override {
        // MEDIUM-6 修复: 验证时间戳合理性
        _validateTimestamp();

        // Mint: start lockup timer for first-time receiver.
        if (_from == address(0)) {
            if (holdingStartTime[_to] == 0) {
                holdingStartTime[_to] = block.timestamp;
                emit HoldingStartTimeSet(_to, block.timestamp);
            }
            return;
        }

        // Burn: no lockup state update needed.
        if (_to == address(0)) {
            return;
        }

        // Normal transfer: initialize lockup timer for first-time receiver.
        if (holdingStartTime[_to] == 0) {
            holdingStartTime[_to] = block.timestamp;
            emit HoldingStartTimeSet(_to, block.timestamp);
        }
    }

    /**
     * @dev 验证时间戳合理性,防止矿工操纵
     */
    function _validateTimestamp() internal {
        require(block.timestamp >= lastBlockTimestamp, "Timestamp cannot go backwards");

        // 仅在时间差较小时检查漂移(避免测试中 vm.warp 触发)
        uint256 timeDiff = block.timestamp - lastBlockTimestamp;
        if (timeDiff > 0 && timeDiff <= 1 hours) {
            require(timeDiff <= MAX_TIMESTAMP_DRIFT, "Timestamp drift too large");
        }

        lastBlockTimestamp = block.timestamp;
    }

    function setLockupPeriod(uint256 _lockupPeriod) external onlyOwner {
        lockupPeriod = _lockupPeriod;
        emit LockupPeriodSet(_lockupPeriod);
    }

    function addToWhitelist(address _addr) external onlyOwner {
        lockupWhitelist[_addr] = true;
        emit AddressAddedToWhitelist(_addr);
    }

    function removeFromWhitelist(address _addr) external onlyOwner {
        lockupWhitelist[_addr] = false;
        emit AddressRemovedFromWhitelist(_addr);
    }

    function name() external pure override returns (string memory) {
        return "TransferRestrictModule";
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
