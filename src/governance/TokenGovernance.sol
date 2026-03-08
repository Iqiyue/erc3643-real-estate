// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TokenGovernance
 * @dev 多签名治理合约,管理平台关键操作,包含时间锁保护和目标白名单
 */
contract TokenGovernance {
    // 常量定义
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant GRACE_PERIOD = 7 days;

    struct Proposal {
        address target;         // 20 bytes
        bool executed;          // 1 byte
        uint256 value;          // 32 bytes (新槽)
        uint256 confirmations;  // 32 bytes (新槽)
        uint256 queuedAt;       // 32 bytes (新槽)
        bytes data;             // 动态大小
        string description;     // 动态大小
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;

    // MEDIUM-3 修复: 添加 owner 索引映射,优化移除操作
    mapping(address => uint256) public ownerIndex;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public isConfirmed;
    uint256 public proposalCount;
    bytes32 public currentExecutionHash;

    // 新增: 目标合约白名单
    mapping(address => bool) public allowedTargets;

    // 新增: 函数选择器白名单 (target => selector => allowed)
    mapping(address => mapping(bytes4 => bool)) public allowedFunctions;
    bool public whitelistBootstrapped;

    event ProposalSubmitted(uint256 indexed proposalId, address indexed target, uint256 value, string description);
    event ProposalConfirmed(uint256 indexed proposalId, address indexed owner);
    event ProposalRevoked(uint256 indexed proposalId, address indexed owner);
    event ProposalQueued(uint256 indexed proposalId, uint256 executeAfter);  // 新增
    event ProposalExecuted(uint256 indexed proposalId);
    event ExecutionContextSet(bytes32 indexed executionHash);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);
    event TargetAllowed(address indexed target);  // 新增
    event TargetDisallowed(address indexed target);  // 新增
    event FunctionAllowed(address indexed target, bytes4 indexed selector);  // 新增
    event FunctionDisallowed(address indexed target, bytes4 indexed selector);  // 新增

    // 自定义错误
    error Unauthorized(address caller);
    error ProposalNotQueued(uint256 proposalId);
    error TimelockNotExpired(uint256 proposalId, uint256 executeAfter);
    error ProposalExpired(uint256 proposalId);
    error TargetNotAllowed(address target);  // 新增
    error FunctionNotAllowed(address target, bytes4 selector);  // 新增
    error InvalidTarget(address target);  // 新增
    error LengthMismatch();
    error WhitelistAlreadyBootstrapped();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /**
     * @notice 一次性初始化白名单,用于治理自举
     * @dev 仅限 owner 调用一次; 完成后请通过治理流程维护白名单
     */
    function bootstrapWhitelist(
        address[] calldata _targets,
        bytes4[] calldata _selectors
    ) external onlyOwner {
        if (whitelistBootstrapped) revert WhitelistAlreadyBootstrapped();
        if (_targets.length != _selectors.length) revert LengthMismatch();

        for (uint256 i = 0; i < _targets.length; i++) {
            if (_targets[i] == address(0)) revert InvalidTarget(_targets[i]);
            allowedTargets[_targets[i]] = true;
            allowedFunctions[_targets[i]][_selectors[i]] = true;
            emit TargetAllowed(_targets[i]);
            emit FunctionAllowed(_targets[i], _selectors[i]);
        }

        whitelistBootstrapped = true;
    }

    modifier proposalExists(uint256 _proposalId) {
        _proposalExists(_proposalId);
        _;
    }

    modifier notExecuted(uint256 _proposalId) {
        _notExecuted(_proposalId);
        _;
    }

    modifier notConfirmed(uint256 _proposalId) {
        _notConfirmed(_proposalId);
        _;
    }

    function _onlyOwner() internal view {
        if (!isOwner[msg.sender]) revert Unauthorized(msg.sender);
    }

    function _proposalExists(uint256 _proposalId) internal view {
        require(_proposalId < proposalCount, "Proposal does not exist");
    }

    function _notExecuted(uint256 _proposalId) internal view {
        require(!proposals[_proposalId].executed, "Already executed");
    }

    function _notConfirmed(uint256 _proposalId) internal view {
        require(!isConfirmed[_proposalId][msg.sender], "Already confirmed");
    }

    constructor(address[] memory _owners, uint256 _required) {
        require(_owners.length > 0, "Owners required");
        require(_owners.length <= 20, "Too many owners"); // LOW-5: 限制 owner 数量
        require(_required > 0 && _required <= _owners.length, "Invalid required number");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Owner not unique");

            isOwner[owner] = true;
            owners.push(owner);
            // MEDIUM-3 修复: 初始化 owner 索引
            ownerIndex[owner] = i;
        }

        required = _required;
    }

    /**
     * @dev 提交提案
     */
    function submitProposal(
        address _target,
        bytes memory _data,
        uint256 _value,
        string memory _description
    ) external onlyOwner returns (uint256) {
        if (_target == address(0)) revert InvalidTarget(_target);

        // 验证目标合约在白名单中
        if (!allowedTargets[_target]) revert TargetNotAllowed(_target);

        // 验证函数选择器在白名单中
        bytes4 selector;
        if (_data.length >= 4) {
            assembly {
                selector := mload(add(_data, 32))
            }
        }
        if (!allowedFunctions[_target][selector]) {
            revert FunctionNotAllowed(_target, selector);
        }

        uint256 proposalId = proposalCount;
        Proposal storage proposal = proposals[proposalId];

        proposal.target = _target;
        proposal.data = _data;
        proposal.value = _value;
        proposal.description = _description;
        proposal.confirmations = 0;
        proposal.executed = false;

        proposalCount++;

        emit ProposalSubmitted(proposalId, _target, _value, _description);
        return proposalId;
    }

    /**
     * @dev 确认提案
     */
    function confirmProposal(uint256 _proposalId)
        external
        onlyOwner
        proposalExists(_proposalId)
        notExecuted(_proposalId)
        notConfirmed(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        isConfirmed[_proposalId][msg.sender] = true;
        proposal.confirmations++;

        emit ProposalConfirmed(_proposalId, msg.sender);
    }

    /**
     * @dev 撤销确认
     */
    function revokeConfirmation(uint256 _proposalId)
        external
        onlyOwner
        proposalExists(_proposalId)
        notExecuted(_proposalId)
    {
        require(isConfirmed[_proposalId][msg.sender], "Not confirmed");

        Proposal storage proposal = proposals[_proposalId];

        // 禁止在提案已排队后撤销确认
        require(proposal.queuedAt == 0, "Cannot revoke after queued");

        isConfirmed[_proposalId][msg.sender] = false;
        proposal.confirmations--;

        emit ProposalRevoked(_proposalId, msg.sender);
    }

    /**
     * @notice 将提案加入执行队列
     * @param _proposalId 提案 ID
     */
    function queueProposal(uint256 _proposalId)
        external
        onlyOwner
        proposalExists(_proposalId)
        notExecuted(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.confirmations >= required, "Not enough confirmations");
        require(proposal.queuedAt == 0, "Already queued");

        proposal.queuedAt = block.timestamp;

        emit ProposalQueued(_proposalId, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice 执行提案(需要等待时间锁)
     * @param _proposalId 提案 ID
     */
    function executeProposal(uint256 _proposalId)
        external
        onlyOwner
        proposalExists(_proposalId)
        notExecuted(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.confirmations >= required, "Not enough confirmations");

        // 检查时间锁
        if (proposal.queuedAt == 0) revert ProposalNotQueued(_proposalId);
        if (block.timestamp < proposal.queuedAt + TIMELOCK_DELAY) {
            revert TimelockNotExpired(_proposalId, proposal.queuedAt + TIMELOCK_DELAY);
        }
        if (block.timestamp > proposal.queuedAt + TIMELOCK_DELAY + GRACE_PERIOD) {
            revert ProposalExpired(_proposalId);
        }

        proposal.executed = true;

        currentExecutionHash = keccak256(abi.encode(proposal.target, proposal.data, proposal.value));
        emit ExecutionContextSet(currentExecutionHash);
        (bool success, ) = proposal.target.call{value: proposal.value}(proposal.data);
        currentExecutionHash = bytes32(0);
        emit ExecutionContextSet(bytes32(0));
        require(success, "Execution failed");

        emit ProposalExecuted(_proposalId);
    }

    /**
     * @dev 添加所有者
     */
    function addOwner(address _owner) external {
        require(msg.sender == address(this), "Only governance can add owner");
        require(_owner != address(0), "Invalid owner");
        require(!isOwner[_owner], "Owner already exists");

        isOwner[_owner] = true;
        // MEDIUM-3 修复: 记录新 owner 的索引
        ownerIndex[_owner] = owners.length;
        owners.push(_owner);

        emit OwnerAdded(_owner);
    }

    /**
     * @dev 移除所有者
     * @dev MEDIUM-3 修复: 使用索引映射优化,避免循环查找
     */
    function removeOwner(address _owner) external {
        require(msg.sender == address(this), "Only governance can remove owner");
        require(isOwner[_owner], "Not an owner");
        require(owners.length - 1 >= required, "Cannot remove owner");

        isOwner[_owner] = false;

        // MEDIUM-3 修复: 使用索引直接访问,O(1) 复杂度
        uint256 index = ownerIndex[_owner];
        address lastOwner = owners[owners.length - 1];

        // 将最后一个 owner 移到被删除的位置
        owners[index] = lastOwner;
        ownerIndex[lastOwner] = index;

        // 删除最后一个元素
        owners.pop();
        delete ownerIndex[_owner];

        emit OwnerRemoved(_owner);
    }

    /**
     * @dev 修改所需确认数
     */
    function changeRequirement(uint256 _required) external {
        require(msg.sender == address(this), "Only governance can change requirement");
        require(_required > 0 && _required <= owners.length, "Invalid required number");

        required = _required;
        emit RequirementChanged(_required);
    }

    /**
     * @notice 添加允许的目标合约
     * @param _target 目标合约地址
     */
    function allowTarget(address _target) external {
        require(msg.sender == address(this), "Only governance can allow target");
        require(_target != address(0), "Invalid target");

        allowedTargets[_target] = true;
        emit TargetAllowed(_target);
    }

    /**
     * @notice 移除允许的目标合约
     * @param _target 目标合约地址
     */
    function disallowTarget(address _target) external {
        require(msg.sender == address(this), "Only governance can disallow target");

        allowedTargets[_target] = false;
        emit TargetDisallowed(_target);
    }

    /**
     * @notice 添加允许的函数选择器
     * @param _target 目标合约地址
     * @param _selector 函数选择器
     */
    function allowFunction(address _target, bytes4 _selector) external {
        require(msg.sender == address(this), "Only governance can allow function");
        require(_target != address(0), "Invalid target");

        allowedFunctions[_target][_selector] = true;
        emit FunctionAllowed(_target, _selector);
    }

    /**
     * @notice 移除允许的函数选择器
     * @param _target 目标合约地址
     * @param _selector 函数选择器
     */
    function disallowFunction(address _target, bytes4 _selector) external {
        require(msg.sender == address(this), "Only governance can disallow function");

        allowedFunctions[_target][_selector] = false;
        emit FunctionDisallowed(_target, _selector);
    }

    /**
     * @notice 批量添加允许的目标和函数
     * @param _targets 目标合约地址数组
     * @param _selectors 函数选择器数组
     */
    function batchAllowFunctions(
        address[] calldata _targets,
        bytes4[] calldata _selectors
    ) external {
        require(msg.sender == address(this), "Only governance can batch allow");
        require(_targets.length == _selectors.length, "Length mismatch");

        for (uint256 i = 0; i < _targets.length; i++) {
            allowedTargets[_targets[i]] = true;
            allowedFunctions[_targets[i]][_selectors[i]] = true;
            emit TargetAllowed(_targets[i]);
            emit FunctionAllowed(_targets[i], _selectors[i]);
        }
    }

    /**
     * @dev 获取所有所有者
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /**
     * @dev 获取提案信息
     */
    function getProposal(uint256 _proposalId)
        external
        view
        returns (
            address target,
            bytes memory data,
            uint256 value,
            string memory description,
            uint256 confirmations,
            bool executed
        )
    {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.target,
            proposal.data,
            proposal.value,
            proposal.description,
            proposal.confirmations,
            proposal.executed
        );
    }

    /**
     * @dev 检查提案是否被确认
     */
    function isProposalConfirmed(uint256 _proposalId, address _owner) external view returns (bool) {
        return isConfirmed[_proposalId][_owner];
    }

    receive() external payable {}
}
