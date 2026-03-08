// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../identity/IdentityRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../identity/IdentityRegistryStorage.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../compliance/ModularCompliance.sol";

contract RealEstateToken is ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    // 常量定义
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant UPGRADE_TIMELOCK = 7 days;  // 升级时间锁: 7天
    uint256 public constant CANCEL_COOLDOWN = 2 days;  // 取消后的冷却期: 2天
    uint256 public constant SYSTEM_UPDATE_DELAY = 2 days;

    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;

    address[] private investors;
    mapping(address => bool) public isInvestor;
    mapping(address => uint256) private investorIndexPlusOne;
    uint256 public investorCount;
    mapping(address => bool) public isAgent;
    mapping(address => bool) public frozen;

    // 存储槽优化: 将 guardian (20 bytes) 和两个 bool (1 byte each) 打包到一个槽中
    address public guardian;  // Guardian 角色
    bool public forcedTransferRequiresSenderVerified;
    bool public forcedTransferHonorsSenderFreeze;
    bool private isUpgradeExecutionInProgress;

    // HIGH-5 修复: Guardian 暂停限制
    uint256 public lastEmergencyPauseTime;
    uint256 public constant EMERGENCY_PAUSE_COOLDOWN = 24 hours;
    uint256 public constant EMERGENCY_PAUSE_DURATION = 24 hours;

    // MEDIUM-5 修复: Mint 抢跑攻击防护
    mapping(address => uint256) public lastMintTime;
    uint256 public constant MIN_MINT_INTERVAL = 1 minutes;

    // 升级时间锁相关
    struct UpgradeProposal {
        address newImplementation;  // 20 bytes
        bool executed;              // 1 byte
        bool cancelled;             // 1 byte
        uint256 scheduledTime;      // 32 bytes (新槽)
        uint256 cancelledAt;        // 32 bytes (新槽)
    }
    UpgradeProposal public pendingUpgrade;

    // 自定义错误
    error InvalidAddress(address addr);
    error InvalidAmount(uint256 amount);
    error ExceedsMaxSupply(uint256 requested, uint256 max);
    error AddressFrozen(address addr);
    error NotVerified(address addr);
    error Unauthorized(address caller);
    error UpgradeNotScheduled();
    error UpgradeAlreadyScheduled();
    error UpgradeTimelockNotExpired(uint256 currentTime, uint256 scheduledTime);
    error UpgradeExpired(uint256 currentTime, uint256 expiryTime);
    error UpgradeAlreadyExecuted();
    error UpgradeAlreadyCancelled();
    error CancelCooldownNotExpired(uint256 currentTime, uint256 cooldownEnd);  // 新增
    error UpgradeMustUseExecuteFlow();
    error UpgradeImplementationMismatch(address expected, address provided);
    error ComplianceNotBoundToToken(address compliance, address token);
    error SystemUpdateNotScheduled();
    error SystemUpdateTimelockNotExpired(uint256 currentTime, uint256 executeAfter);
    error SystemUpdateTargetMismatch(address expected, address provided);
    error InvalidIdentityRegistryConfig(address registry);

    event IdentityRegistrySet(address indexed identityRegistry);
    event ComplianceSet(address indexed compliance);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);
    event FrozenStatusChanged(address indexed addr, bool frozen);
    event GuardianSet(address indexed guardian);  // 新增
    event UpgradeScheduled(address indexed newImplementation, uint256 scheduledTime);
    event UpgradeExecuted(address indexed newImplementation);
    event UpgradeCancelled(address indexed newImplementation);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event RecoverySuccess(address indexed lostWallet, address indexed newWallet, uint256 amountRecovered);
    event IdentityRegistryUpdateScheduled(address indexed newIdentityRegistry, uint256 executeAfter);
    event ComplianceUpdateScheduled(address indexed newCompliance, uint256 executeAfter);
    event IdentityRegistryUpdateCancelled();
    event ComplianceUpdateCancelled();
    event ForcedTransferPolicyUpdated(bool requiresSenderVerified, bool honorsSenderFreeze);

    modifier onlyAgent() {
        _onlyAgent();
        _;
    }

    modifier notFrozen(address _addr) {
        _notFrozen(_addr);
        _;
    }

    function _onlyAgent() internal view {
        if (!isAgent[msg.sender]) revert Unauthorized(msg.sender);
    }

    function _notFrozen(address _addr) internal view {
        require(!frozen[_addr], "Address frozen");
    }

    struct PendingAddressUpdate {
        address newAddress;
        uint256 executeAfter;
        bool exists;
    }
    PendingAddressUpdate public pendingIdentityRegistryUpdate;
    PendingAddressUpdate public pendingComplianceUpdate;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory _name, string memory _symbol, address _identityRegistry, address _compliance) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();

        identityRegistry = IdentityRegistry(_identityRegistry);
        compliance = ModularCompliance(_compliance);

        emit IdentityRegistrySet(_identityRegistry);
        emit ComplianceSet(_compliance);
    }

    function transfer(address to, uint256 value) public override whenNotPaused notFrozen(msg.sender) notFrozen(to) returns (bool) {
        require(identityRegistry.isVerified(msg.sender), "Sender not verified");
        require(identityRegistry.isVerified(to), "Receiver not verified");
        require(compliance.canTransfer(msg.sender, to, value), "Transfer not compliant");

        bool success = super.transfer(to, value);
        if (success) {
            _updateInvestorListAfterTransfer(msg.sender, to);
            compliance.postTransferHook(msg.sender, to, value);
        }
        return success;
    }

    function transferFrom(address from, address to, uint256 value) public override whenNotPaused notFrozen(from) notFrozen(to) returns (bool) {
        require(identityRegistry.isVerified(from), "Sender not verified");
        require(identityRegistry.isVerified(to), "Receiver not verified");
        require(compliance.canTransfer(from, to, value), "Transfer not compliant");

        bool success = super.transferFrom(from, to, value);
        if (success) {
            _updateInvestorListAfterTransfer(from, to);
            compliance.postTransferHook(from, to, value);
        }
        return success;
    }

    /**
     * @notice 铸造代币
     * @param to 接收地址
     * @param amount 铸造数量
     */
    function mint(address to, uint256 amount) external onlyAgent whenNotPaused notFrozen(to) {
        if (to == address(0)) revert InvalidAddress(to);
        if (amount == 0) revert InvalidAmount(amount);
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply(totalSupply() + amount, MAX_SUPPLY);
        if (!identityRegistry.isVerified(to)) revert NotVerified(to);

        // MEDIUM-5 修复: 防止同一地址短时间内多次 mint (抢跑攻击)
        // 仅在非零时检查,允许首次 mint
        if (lastMintTime[to] > 0) {
            require(block.timestamp >= lastMintTime[to] + MIN_MINT_INTERVAL, "Mint too frequent");
        }
        lastMintTime[to] = block.timestamp;

        require(compliance.canTransfer(address(0), to, amount), "Mint not compliant");

        _mint(to, amount);
        _updateInvestorListAfterTransfer(address(0), to);
        compliance.postTransferHook(address(0), to, amount);
    }

    /**
     * @notice 销毁代币
     * @param from 销毁地址
     * @param amount 销毁数量
     */
    function burn(address from, uint256 amount) external onlyAgent whenNotPaused {
        if (from == address(0)) revert InvalidAddress(from);
        if (amount == 0) revert InvalidAmount(amount);

        require(compliance.canTransfer(from, address(0), amount), "Burn not compliant");

        _burn(from, amount);
        _updateInvestorListAfterTransfer(from, address(0));
        compliance.postTransferHook(from, address(0), amount);
    }

    /**
     * @notice 批量铸造代币 (绕过单次铸造时间限制)
     * @param recipients 接收地址数组
     * @param amounts 铸造数量数组
     */
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external onlyAgent whenNotPaused {
        require(recipients.length == amounts.length, "Array length mismatch");
        require(recipients.length <= 100, "Batch size too large");

        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];

            if (to == address(0)) revert InvalidAddress(to);
            if (amount == 0) continue; // Skip zero amounts
            if (frozen[to]) revert AddressFrozen(to);
            if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply(totalSupply() + amount, MAX_SUPPLY);
            if (!identityRegistry.isVerified(to)) revert NotVerified(to);

            require(compliance.canTransfer(address(0), to, amount), "Mint not compliant");

            _mint(to, amount);
            _updateInvestorListAfterTransfer(address(0), to);
            compliance.postTransferHook(address(0), to, amount);
        }
    }

    function _updateInvestorListAfterTransfer(address from, address to) internal {
        if (from == address(0)) {
            if (!isInvestor[to] && balanceOf(to) > 0) {
                investorIndexPlusOne[to] = investors.length + 1;
                investors.push(to);
                isInvestor[to] = true;
                investorCount++;
            }
            return;
        }

        if (to == address(0)) {
            if (balanceOf(from) == 0 && isInvestor[from]) {
                _removeInvestor(from);
            }
            return;
        }

        if (balanceOf(from) == 0 && isInvestor[from]) {
            _removeInvestor(from);
        }

        if (!isInvestor[to] && balanceOf(to) > 0) {
            investorIndexPlusOne[to] = investors.length + 1;
            investors.push(to);
            isInvestor[to] = true;
            investorCount++;
        }
    }

    function _removeInvestor(address investor) internal {
        uint256 indexPlusOne = investorIndexPlusOne[investor];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = investors.length - 1;

        if (index != lastIndex) {
            address lastInvestor = investors[lastIndex];
            investors[index] = lastInvestor;
            investorIndexPlusOne[lastInvestor] = index + 1;
        }

        investors.pop();
        delete investorIndexPlusOne[investor];
        isInvestor[investor] = false;
        investorCount--;
    }

    /**
     * @notice 添加代理人
     * @param agent 代理人地址
     */
    function addAgent(address agent) external onlyOwner {
        if (agent == address(0)) revert InvalidAddress(agent);
        isAgent[agent] = true;
        emit AgentAdded(agent);
    }

    /**
     * @notice 移除代理人
     * @param agent 代理人地址
     */
    function removeAgent(address agent) external onlyOwner {
        isAgent[agent] = false;
        emit AgentRemoved(agent);
    }

    /**
     * @notice 设置 Guardian
     * @param _guardian Guardian 地址
     */
    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert InvalidAddress(_guardian);
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    /**
     * @notice 紧急暂停(Guardian 或 Owner 可调用)
     * @dev HIGH-5 修复: 添加冷却期和自动恢复机制
     */
    function emergencyPause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert Unauthorized(msg.sender);

        // Guardian 调用时检查冷却期
        if (msg.sender == guardian) {
            require(
                block.timestamp > lastEmergencyPauseTime + EMERGENCY_PAUSE_COOLDOWN,
                "Emergency pause cooldown not expired"
            );
            lastEmergencyPauseTime = block.timestamp;
        }

        _pause();
    }

    /**
     * @notice 自动恢复 (任何人都可以在暂停期结束后调用)
     * @dev HIGH-5 修复: 防止无限期暂停
     */
    function autoUnpause() external {
        require(paused(), "Not paused");
        require(
            block.timestamp > lastEmergencyPauseTime + EMERGENCY_PAUSE_DURATION,
            "Emergency pause still active"
        );
        _unpause();
    }

    /**
     * @notice 冻结地址
     * @param addr 要冻结的地址
     */
    function freezeAddress(address addr) external onlyAgent {
        if (addr == address(0)) revert InvalidAddress(addr);
        frozen[addr] = true;
        emit FrozenStatusChanged(addr, true);
    }

    /**
     * @notice 解冻地址
     * @param addr 要解冻的地址
     */
    function unfreezeAddress(address addr) external onlyAgent {
        frozen[addr] = false;
        emit FrozenStatusChanged(addr, false);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getInvestors() external view returns (address[] memory) {
        return investors;
    }

    function scheduleIdentityRegistryUpdate(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert InvalidAddress(_identityRegistry);
        _validateIdentityRegistry(_identityRegistry);
        pendingIdentityRegistryUpdate = PendingAddressUpdate({
            newAddress: _identityRegistry,
            executeAfter: block.timestamp + SYSTEM_UPDATE_DELAY,
            exists: true
        });
        emit IdentityRegistryUpdateScheduled(_identityRegistry, block.timestamp + SYSTEM_UPDATE_DELAY);
    }

    function cancelIdentityRegistryUpdate() external onlyOwner {
        if (!pendingIdentityRegistryUpdate.exists) revert SystemUpdateNotScheduled();
        delete pendingIdentityRegistryUpdate;
        emit IdentityRegistryUpdateCancelled();
    }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (!pendingIdentityRegistryUpdate.exists) revert SystemUpdateNotScheduled();
        if (pendingIdentityRegistryUpdate.newAddress != _identityRegistry) {
            revert SystemUpdateTargetMismatch(pendingIdentityRegistryUpdate.newAddress, _identityRegistry);
        }
        if (block.timestamp < pendingIdentityRegistryUpdate.executeAfter) {
            revert SystemUpdateTimelockNotExpired(block.timestamp, pendingIdentityRegistryUpdate.executeAfter);
        }
        _validateIdentityRegistry(_identityRegistry);
        identityRegistry = IdentityRegistry(_identityRegistry);
        delete pendingIdentityRegistryUpdate;
        emit IdentityRegistrySet(_identityRegistry);
    }

    function scheduleComplianceUpdate(address _compliance) external onlyOwner {
        if (_compliance == address(0)) revert InvalidAddress(_compliance);
        if (ModularCompliance(_compliance).tokenBound() != address(this)) {
            revert ComplianceNotBoundToToken(_compliance, address(this));
        }
        pendingComplianceUpdate = PendingAddressUpdate({
            newAddress: _compliance,
            executeAfter: block.timestamp + SYSTEM_UPDATE_DELAY,
            exists: true
        });
        emit ComplianceUpdateScheduled(_compliance, block.timestamp + SYSTEM_UPDATE_DELAY);
    }

    function cancelComplianceUpdate() external onlyOwner {
        if (!pendingComplianceUpdate.exists) revert SystemUpdateNotScheduled();
        delete pendingComplianceUpdate;
        emit ComplianceUpdateCancelled();
    }

    function setCompliance(address _compliance) external onlyOwner {
        if (!pendingComplianceUpdate.exists) revert SystemUpdateNotScheduled();
        if (pendingComplianceUpdate.newAddress != _compliance) {
            revert SystemUpdateTargetMismatch(pendingComplianceUpdate.newAddress, _compliance);
        }
        if (block.timestamp < pendingComplianceUpdate.executeAfter) {
            revert SystemUpdateTimelockNotExpired(block.timestamp, pendingComplianceUpdate.executeAfter);
        }
        if (ModularCompliance(_compliance).tokenBound() != address(this)) {
            revert ComplianceNotBoundToToken(_compliance, address(this));
        }
        compliance = ModularCompliance(_compliance);
        delete pendingComplianceUpdate;
        emit ComplianceSet(_compliance);
    }

    function setForcedTransferPolicy(bool requiresSenderVerified, bool honorsSenderFreeze) external onlyOwner {
        forcedTransferRequiresSenderVerified = requiresSenderVerified;
        forcedTransferHonorsSenderFreeze = honorsSenderFreeze;
        emit ForcedTransferPolicyUpdated(requiresSenderVerified, honorsSenderFreeze);
    }

    function forcedTransfer(address from, address to, uint256 amount)
        external
        onlyAgent
        whenNotPaused
        notFrozen(to)
        returns (bool)
    {
        _forcedTransfer(from, to, amount);
        return true;
    }

    function batchForcedTransfer(
        address[] calldata fromList,
        address[] calldata toList,
        uint256[] calldata amountList
    ) external onlyAgent whenNotPaused returns (bool) {
        require(fromList.length == toList.length && fromList.length == amountList.length, "Array length mismatch");
        require(fromList.length > 0, "Empty array");
        require(fromList.length <= 100, "Batch size too large"); // MEDIUM-8 修复: 限制批量大小

        for (uint256 i = 0; i < fromList.length; i++) {
            _forcedTransfer(fromList[i], toList[i], amountList[i]);
        }

        return true;
    }

    function recoveryAddress(address lostWallet, address newWallet) external onlyAgent whenNotPaused returns (bool) {
        if (lostWallet == address(0)) revert InvalidAddress(lostWallet);
        if (newWallet == address(0)) revert InvalidAddress(newWallet);
        if (!identityRegistry.isVerified(newWallet)) revert NotVerified(newWallet);

        uint256 amount = balanceOf(lostWallet);
        if (amount == 0) return true;
        _forcedTransfer(lostWallet, newWallet, amount);
        emit RecoverySuccess(lostWallet, newWallet, amount);
        return true;
    }

    function _forcedTransfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert InvalidAddress(from);
        if (to == address(0)) revert InvalidAddress(to);
        if (amount == 0) revert InvalidAmount(amount);
        if (forcedTransferHonorsSenderFreeze && frozen[from]) revert AddressFrozen(from);
        if (frozen[to]) revert AddressFrozen(to);
        if (forcedTransferRequiresSenderVerified && !identityRegistry.isVerified(from)) revert NotVerified(from);
        if (!identityRegistry.isVerified(to)) revert NotVerified(to);
        require(compliance.canTransfer(from, to, amount), "Transfer not compliant");

        _transfer(from, to, amount);
        _updateInvestorListAfterTransfer(from, to);
        compliance.postTransferHook(from, to, amount);
        emit ForcedTransfer(from, to, amount);
    }

    function _validateIdentityRegistry(address registryAddr) internal view {
        IdentityRegistry registry = IdentityRegistry(registryAddr);
        address storageAddr = address(registry.identityStorage());
        if (storageAddr == address(0)) revert InvalidIdentityRegistryConfig(registryAddr);
        if (IdentityRegistryStorage(storageAddr).identityRegistry() != registryAddr) {
            revert InvalidIdentityRegistryConfig(registryAddr);
        }

        try registry.trustedIssuersList(0) returns (address firstIssuer) {
            if (!registry.trustedIssuers(firstIssuer)) revert InvalidIdentityRegistryConfig(registryAddr);
        } catch {
            revert InvalidIdentityRegistryConfig(registryAddr);
        }

        try registry.claimTopicsRequired(0) returns (uint256) {} catch {
            revert InvalidIdentityRegistryConfig(registryAddr);
        }
    }

    /**
     * @notice 安排升级 (需要时间锁)
     * @param newImplementation 新实现合约地址
     */
    function scheduleUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert InvalidAddress(newImplementation);
        if (pendingUpgrade.scheduledTime != 0 && !pendingUpgrade.executed && !pendingUpgrade.cancelled) {
            revert UpgradeAlreadyScheduled();
        }

        // 如果之前取消过升级，检查冷却期
        if (pendingUpgrade.cancelled && pendingUpgrade.cancelledAt > 0) {
            uint256 cooldownEnd = pendingUpgrade.cancelledAt + CANCEL_COOLDOWN;
            if (block.timestamp < cooldownEnd) {
                revert CancelCooldownNotExpired(block.timestamp, cooldownEnd);
            }
        }

        uint256 scheduledTime = block.timestamp + UPGRADE_TIMELOCK;

        pendingUpgrade = UpgradeProposal({
            newImplementation: newImplementation,
            scheduledTime: scheduledTime,
            executed: false,
            cancelled: false,
            cancelledAt: 0
        });

        emit UpgradeScheduled(newImplementation, scheduledTime);
    }

    /**
     * @notice 执行已安排的升级
     */
    function executeUpgrade() external onlyOwner {
        if (pendingUpgrade.scheduledTime == 0) revert UpgradeNotScheduled();
        if (pendingUpgrade.executed) revert UpgradeAlreadyExecuted();
        if (pendingUpgrade.cancelled) revert UpgradeAlreadyCancelled();
        if (block.timestamp < pendingUpgrade.scheduledTime) {
            revert UpgradeTimelockNotExpired(block.timestamp, pendingUpgrade.scheduledTime);
        }

        // 升级有效期: 安排时间后 7 天内必须执行
        uint256 expiryTime = pendingUpgrade.scheduledTime + 7 days;
        if (block.timestamp > expiryTime) {
            revert UpgradeExpired(block.timestamp, expiryTime);
        }

        address newImplementation = pendingUpgrade.newImplementation;
        pendingUpgrade.executed = true;
        isUpgradeExecutionInProgress = true;

        upgradeToAndCall(newImplementation, new bytes(0));
        isUpgradeExecutionInProgress = false;

        emit UpgradeExecuted(newImplementation);
    }

    /**
     * @notice 取消已安排的升级
     */
    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade.scheduledTime == 0) revert UpgradeNotScheduled();
        if (pendingUpgrade.executed) revert UpgradeAlreadyExecuted();
        if (pendingUpgrade.cancelled) revert UpgradeAlreadyCancelled();

        address cancelledImplementation = pendingUpgrade.newImplementation;
        pendingUpgrade.cancelled = true;
        pendingUpgrade.cancelledAt = block.timestamp;  // 记录取消时间

        emit UpgradeCancelled(cancelledImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!isUpgradeExecutionInProgress) revert UpgradeMustUseExecuteFlow();
        if (pendingUpgrade.scheduledTime == 0) revert UpgradeNotScheduled();
        if (pendingUpgrade.cancelled) revert UpgradeAlreadyCancelled();
        if (pendingUpgrade.newImplementation != newImplementation) {
            revert UpgradeImplementationMismatch(pendingUpgrade.newImplementation, newImplementation);
        }
    }
}
