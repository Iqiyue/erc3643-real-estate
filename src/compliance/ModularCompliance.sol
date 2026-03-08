// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ComplianceModule.sol";

contract ModularCompliance is Ownable {
    address public tokenBound;
    address[] public modules;
    mapping(address => bool) public isModuleBound;

    // HIGH-1 修复: 添加模块时间锁
    uint256 public constant MODULE_TIMELOCK = 2 days;

    struct PendingModule {
        address module;
        uint256 executeAfter;
        bool isAddition; // true = add, false = remove
        bool exists;
    }

    mapping(bytes32 => PendingModule) public pendingModules;

    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);
    event ModuleScheduled(address indexed module, bool isAddition, uint256 executeAfter);
    event ModuleScheduleCancelled(address indexed module, bool isAddition);
    event TokenBound(address indexed token);
    event TransferActionProcessed(address indexed from, address indexed to, uint256 value);

    constructor() Ownable(msg.sender) {}

    modifier onlyBoundToken() {
        _onlyBoundToken();
        _;
    }

    function _onlyBoundToken() internal view {
        require(msg.sender == tokenBound, "Only bound token");
    }

    function bindToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        require(tokenBound == address(0), "Token already bound");
        tokenBound = _token;
        emit TokenBound(_token);
    }

    /**
     * @notice 调度添加模块 (需要时间锁)
     * @param _module 模块地址
     */
    function scheduleAddModule(address _module) external onlyOwner {
        require(_module != address(0), "Invalid module");
        require(!isModuleBound[_module], "Module already bound");

        bytes32 scheduleId = keccak256(abi.encodePacked(_module, true));
        require(!pendingModules[scheduleId].exists, "Already scheduled");

        pendingModules[scheduleId] = PendingModule({
            module: _module,
            executeAfter: block.timestamp + MODULE_TIMELOCK,
            isAddition: true,
            exists: true
        });

        emit ModuleScheduled(_module, true, block.timestamp + MODULE_TIMELOCK);
    }

    /**
     * @notice 执行添加模块
     * @param _module 模块地址
     */
    function addModule(address _module) external onlyOwner {
        bytes32 scheduleId = keccak256(abi.encodePacked(_module, true));
        PendingModule memory pending = pendingModules[scheduleId];

        require(pending.exists, "Not scheduled");
        require(block.timestamp >= pending.executeAfter, "Timelock not expired");
        require(!isModuleBound[_module], "Module already bound");

        modules.push(_module);
        isModuleBound[_module] = true;
        ComplianceModule(_module).bindCompliance(address(this));

        delete pendingModules[scheduleId];
        emit ModuleAdded(_module);
    }

    /**
     * @notice 调度移除模块 (需要时间锁)
     * @param _module 模块地址
     */
    function scheduleRemoveModule(address _module) external onlyOwner {
        require(isModuleBound[_module], "Module not bound");

        bytes32 scheduleId = keccak256(abi.encodePacked(_module, false));
        require(!pendingModules[scheduleId].exists, "Already scheduled");

        pendingModules[scheduleId] = PendingModule({
            module: _module,
            executeAfter: block.timestamp + MODULE_TIMELOCK,
            isAddition: false,
            exists: true
        });

        emit ModuleScheduled(_module, false, block.timestamp + MODULE_TIMELOCK);
    }

    /**
     * @notice 执行移除模块
     * @param _module 模块地址
     */
    function removeModule(address _module) external onlyOwner {
        bytes32 scheduleId = keccak256(abi.encodePacked(_module, false));
        PendingModule memory pending = pendingModules[scheduleId];

        require(pending.exists, "Not scheduled");
        require(block.timestamp >= pending.executeAfter, "Timelock not expired");
        require(isModuleBound[_module], "Module not bound");

        for (uint256 i = 0; i < modules.length; i++) {
            if (modules[i] == _module) {
                modules[i] = modules[modules.length - 1];
                modules.pop();
                break;
            }
        }
        isModuleBound[_module] = false;
        ComplianceModule(_module).unbindCompliance(address(this));

        delete pendingModules[scheduleId];
        emit ModuleRemoved(_module);
    }

    /**
     * @notice 取消模块调度
     * @param _module 模块地址
     * @param _isAddition 是否是添加操作
     */
    function cancelModuleSchedule(address _module, bool _isAddition) external onlyOwner {
        bytes32 scheduleId = keccak256(abi.encodePacked(_module, _isAddition));
        require(pendingModules[scheduleId].exists, "Not scheduled");

        delete pendingModules[scheduleId];
        emit ModuleScheduleCancelled(_module, _isAddition);
    }

    function canTransfer(address _from, address _to, uint256 _value) external view returns (bool) {
        for (uint256 i = 0; i < modules.length; i++) {
            if (!ComplianceModule(modules[i]).moduleCheck(_from, _to, _value, address(this))) {
                return false;
            }
        }
        return true;
    }

    function postTransferHook(address _from, address _to, uint256 _value) external onlyBoundToken {
        for (uint256 i = 0; i < modules.length; i++) {
            ComplianceModule(modules[i]).moduleTransferAction(_from, _to, _value, address(this));
        }
        emit TransferActionProcessed(_from, _to, _value);
    }

    function getModules() external view returns (address[] memory) {
        return modules;
    }
}
