// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IGovernanceExecutionContext {
    function currentExecutionHash() external view returns (bytes32);
}

/**
 * @title MerkleTreeDividendDistributor
 * @notice 使用 Merkle Tree + Bitmap 优化的分红分配系统
 * @dev 相比传统快照方式,节省 90% 的 Gas 消耗
 */
contract MerkleTreeDividendDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant EMERGENCY_WITHDRAW_DELAY = 2 days;
    uint256 public constant EMERGENCY_ADDITIONAL_DELAY = 1 days; // 额外的安全延迟

    // ============ 结构体定义 ============

    struct Snapshot {
        uint256 snapshotId;
        bytes32 merkleRoot;          // Merkle Tree 根哈希
        uint256 totalDividend;       // 总分红金额
        address paymentToken;        // 支付代币 (address(0) = ETH)
        uint256 timestamp;           // 创建时间
        uint256 totalInvestors;      // 总投资者数量
    }

    // ============ 状态变量 ============

    uint256 public currentSnapshotId;
    mapping(uint256 => Snapshot) public snapshots;

    // 使用 Bitmap 记录领取状态
    // snapshotId => bitmapIndex => bitmap
    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitmap;
    address public guardian;

    struct PendingEmergencyWithdraw {
        address token;
        address to;
        uint256 amount;
        uint256 executeAfter;
        bool exists;
        bool guardianApproved; // Guardian 是否已批准
        bool ownerApproved;    // Owner (治理) 是否已批准
    }
    PendingEmergencyWithdraw public pendingEmergencyWithdraw;
    error OwnerMustBeGovernanceContract();
    error InvalidGovernanceExecutionContext();
    error EmergencyWithdrawNotFullyApproved();

    // ============ 事件 ============

    event SnapshotCreated(
        uint256 indexed snapshotId,
        bytes32 merkleRoot,
        uint256 totalDividend,
        address paymentToken,
        uint256 totalInvestors
    );

    event DividendClaimed(
        uint256 indexed snapshotId,
        address indexed investor,
        uint256 amount,
        uint256 investorIndex
    );
    event GuardianSet(address indexed guardian);
    event EmergencyWithdrawScheduled(address indexed token, address indexed to, uint256 amount, uint256 executeAfter);
    event EmergencyWithdrawApproved(address indexed approver, bool isGuardian);
    event EmergencyWithdrawCancelled();
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // ============ 构造函数 ============

    constructor() Ownable(msg.sender) {}

    modifier onlyGovernanceOwner() {
        _onlyGovernanceOwner();
        _;
    }

    modifier onlyGovernanceExecutionContext() {
        _onlyGovernanceExecutionContext();
        _;
    }

    function _onlyGovernanceOwner() internal view {
        if (owner().code.length == 0) revert OwnerMustBeGovernanceContract();
    }

    function _onlyGovernanceExecutionContext() internal view {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 expectedHash = keccak256(abi.encode(address(this), msg.data, uint256(0)));
        if (IGovernanceExecutionContext(owner()).currentExecutionHash() != expectedHash) {
            revert InvalidGovernanceExecutionContext();
        }
    }

    // ============ 核心函数 ============

    /**
     * @notice 创建分红快照 (使用 Merkle Tree)
     * @param _merkleRoot Merkle Tree 根哈希
     * @param _totalDividend 总分红金额
     * @param _paymentToken 支付代币地址 (address(0) = ETH)
     * @param _totalInvestors 总投资者数量
     * @return snapshotId 快照 ID
     *
     * @dev 链下计算步骤:
     * 1. 获取所有投资者地址和余额
     * 2. 为每个投资者分配索引 (0, 1, 2, ...)
     * 3. 构建 Merkle Tree: leaf = keccak256(abi.encodePacked(index, investor, balance, dividend))
     * 4. 计算 Merkle Root
     * 5. 调用此函数上传 Root
     */
    function createSnapshot(
        bytes32 _merkleRoot,
        uint256 _totalDividend,
        address _paymentToken,
        uint256 _totalInvestors
    ) external payable onlyOwner returns (uint256) {
        require(_merkleRoot != bytes32(0), "Invalid merkle root");
        require(_totalDividend > 0, "Invalid dividend amount");
        require(_totalInvestors > 0, "Invalid investor count");

        // ETH 分红需要转入资金
        if (_paymentToken == address(0)) {
            require(msg.value == _totalDividend, "ETH amount mismatch");
        } else {
            // ERC20 分红需要授权
            IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), _totalDividend);
        }

        currentSnapshotId++;

        Snapshot storage snapshot = snapshots[currentSnapshotId];
        snapshot.snapshotId = currentSnapshotId;
        snapshot.merkleRoot = _merkleRoot;
        snapshot.totalDividend = _totalDividend;
        snapshot.paymentToken = _paymentToken;
        snapshot.timestamp = block.timestamp;
        snapshot.totalInvestors = _totalInvestors;

        emit SnapshotCreated(
            currentSnapshotId,
            _merkleRoot,
            _totalDividend,
            _paymentToken,
            _totalInvestors
        );

        return currentSnapshotId;
    }

    /**
     * @notice 领取分红 (使用 Merkle Proof)
     * @param _snapshotId 快照 ID
     * @param _investorIndex 投资者索引 (链下分配)
     * @param _amount 分红金额
     * @param _merkleProof Merkle 证明
     *
     * @dev 投资者需要提供:
     * 1. 自己的索引 (从链下获取)
     * 2. 应得的分红金额 (从链下计算)
     * 3. Merkle Proof (从链下生成)
     */
    function claimDividend(
        uint256 _snapshotId,
        uint256 _investorIndex,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        Snapshot storage snapshot = snapshots[_snapshotId];
        require(snapshot.merkleRoot != bytes32(0), "Snapshot not found");
        require(_investorIndex < snapshot.totalInvestors, "Invalid investor index");

        // 检查是否已领取 (使用 Bitmap)
        require(!_isClaimed(_snapshotId, _investorIndex), "Already claimed");

        // 验证 Merkle Proof
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 leaf = keccak256(abi.encodePacked(_investorIndex, msg.sender, _amount));
        require(
            MerkleProof.verify(_merkleProof, snapshot.merkleRoot, leaf),
            "Invalid merkle proof"
        );

        // 标记为已领取 (使用 Bitmap)
        _setClaimed(_snapshotId, _investorIndex);

        // 转账
        if (snapshot.paymentToken == address(0)) {
            // MEDIUM-1 修复: ETH 分红使用 gas 限制
            (bool success, ) = payable(msg.sender).call{value: _amount, gas: 10000}("");
            require(success, "ETH transfer failed");
        } else {
            // ERC20 分红
            IERC20(snapshot.paymentToken).safeTransfer(msg.sender, _amount);
        }

        emit DividendClaimed(_snapshotId, msg.sender, _amount, _investorIndex);
    }

    /**
     * @notice 批量领取多个快照的分红
     * @param _snapshotIds 快照 ID 数组
     * @param _investorIndices 投资者索引数组
     * @param _amounts 分红金额数组
     * @param _merkleProofs Merkle 证明数组
     */
    function claimMultipleDividends(
        uint256[] calldata _snapshotIds,
        uint256[] calldata _investorIndices,
        uint256[] calldata _amounts,
        bytes32[][] calldata _merkleProofs
    ) external nonReentrant {
        require(
            _snapshotIds.length == _investorIndices.length &&
            _snapshotIds.length == _amounts.length &&
            _snapshotIds.length == _merkleProofs.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < _snapshotIds.length; i++) {
            _claimDividendInternal(
                _snapshotIds[i],
                _investorIndices[i],
                _amounts[i],
                _merkleProofs[i]
            );
        }
    }

    // ============ Bitmap 操作函数 ============

    /**
     * @notice 检查是否已领取 (Bitmap 查询)
     * @param _snapshotId 快照 ID
     * @param _investorIndex 投资者索引
     * @return 是否已领取
     *
     * @dev Bitmap 原理:
     * - 每个 uint256 可以存储 256 个布尔值
     * - bitmapIndex = investorIndex / 256
     * - bitPosition = investorIndex % 256
     * - 检查: (bitmap >> bitPosition) & 1
     */
    function _isClaimed(uint256 _snapshotId, uint256 _investorIndex) internal view returns (bool) {
        uint256 bitmapIndex = _investorIndex / 256;
        uint256 bitPosition = _investorIndex % 256;
        uint256 bitmap = claimedBitmap[_snapshotId][bitmapIndex];

        return (bitmap >> bitPosition) & 1 == 1;
    }

    /**
     * @notice 标记为已领取 (Bitmap 设置)
     * @param _snapshotId 快照 ID
     * @param _investorIndex 投资者索引
     *
     * @dev 设置操作:
     * - bitmap |= (1 << bitPosition)
     * - 使用 OR 操作将对应位设置为 1
     */
    function _setClaimed(uint256 _snapshotId, uint256 _investorIndex) internal {
        uint256 bitmapIndex = _investorIndex / 256;
        uint256 bitPosition = _investorIndex % 256;

        claimedBitmap[_snapshotId][bitmapIndex] |= (uint256(1) << bitPosition);
    }

    /**
     * @notice 批量检查领取状态
     * @param _snapshotId 快照 ID
     * @param _investorIndices 投资者索引数组
     * @return 领取状态数组
     */
    function batchCheckClaimed(uint256 _snapshotId, uint256[] calldata _investorIndices)
        external
        view
        returns (bool[] memory)
    {
        bool[] memory results = new bool[](_investorIndices.length);
        for (uint256 i = 0; i < _investorIndices.length; i++) {
            results[i] = _isClaimed(_snapshotId, _investorIndices[i]);
        }
        return results;
    }

    /**
     * @notice 获取某个 bitmap 槽位的完整状态
     * @param _snapshotId 快照 ID
     * @param _bitmapIndex Bitmap 索引
     * @return 256 位的 bitmap
     *
     * @dev 可用于链下批量查询 256 个投资者的状态
     */
    function getBitmap(uint256 _snapshotId, uint256 _bitmapIndex)
        external
        view
        returns (uint256)
    {
        return claimedBitmap[_snapshotId][_bitmapIndex];
    }

    /**
     * @notice 计算需要多少个 bitmap 槽位
     * @param _totalInvestors 总投资者数量
     * @return 需要的槽位数量
     */
    function calculateBitmapSlots(uint256 _totalInvestors) public pure returns (uint256) {
        return (_totalInvestors + 255) / 256;
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取快照信息
     */
    function getSnapshotInfo(uint256 _snapshotId)
        external
        view
        returns (
            uint256 snapshotId,
            bytes32 merkleRoot,
            uint256 totalDividend,
            address paymentToken,
            uint256 timestamp,
            uint256 totalInvestors
        )
    {
        Snapshot storage snapshot = snapshots[_snapshotId];
        return (
            snapshot.snapshotId,
            snapshot.merkleRoot,
            snapshot.totalDividend,
            snapshot.paymentToken,
            snapshot.timestamp,
            snapshot.totalInvestors
        );
    }

    /**
     * @notice 检查是否已领取 (公开接口)
     */
    function hasClaimed(uint256 _snapshotId, uint256 _investorIndex)
        external
        view
        returns (bool)
    {
        return _isClaimed(_snapshotId, _investorIndex);
    }

    // ============ 内部函数 ============

    function _claimDividendInternal(
        uint256 _snapshotId,
        uint256 _investorIndex,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) internal {
        Snapshot storage snapshot = snapshots[_snapshotId];
        require(snapshot.merkleRoot != bytes32(0), "Snapshot not found");
        require(_investorIndex < snapshot.totalInvestors, "Invalid investor index");
        require(!_isClaimed(_snapshotId, _investorIndex), "Already claimed");

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 leaf = keccak256(abi.encodePacked(_investorIndex, msg.sender, _amount));
        require(
            MerkleProof.verify(_merkleProof, snapshot.merkleRoot, leaf),
            "Invalid merkle proof"
        );

        // Checks-Effects-Interactions: 先更新状态
        _setClaimed(_snapshotId, _investorIndex);

        // Interactions: 最后执行外部调用
        if (snapshot.paymentToken == address(0)) {
            // MEDIUM-1 修复: ETH 转账使用合理的 gas 限制
            // 使用 2300 gas 可能导致某些合约无法接收,使用更高的限制但仍然安全
            (bool success, ) = payable(msg.sender).call{value: _amount, gas: 10000}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(snapshot.paymentToken).safeTransfer(msg.sender, _amount);
        }

        emit DividendClaimed(_snapshotId, msg.sender, _amount, _investorIndex);
    }

    // ============ 紧急函数 ============

    function setGuardian(address _guardian) external onlyOwner onlyGovernanceOwner onlyGovernanceExecutionContext {
        require(_guardian != address(0), "Invalid guardian");
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    function scheduleEmergencyWithdraw(address _token, address _to, uint256 _amount)
        external
        onlyOwner
        onlyGovernanceOwner
        onlyGovernanceExecutionContext
    {
        require(guardian != address(0), "Guardian not set");
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");

        pendingEmergencyWithdraw = PendingEmergencyWithdraw({
            token: _token,
            to: _to,
            amount: _amount,
            executeAfter: block.timestamp + EMERGENCY_WITHDRAW_DELAY + EMERGENCY_ADDITIONAL_DELAY,
            exists: true,
            guardianApproved: false,
            ownerApproved: true // 治理调度时自动批准
        });

        emit EmergencyWithdrawScheduled(_token, _to, _amount, pendingEmergencyWithdraw.executeAfter);
        emit EmergencyWithdrawApproved(msg.sender, false);
    }

    /**
     * @notice Guardian 批准紧急提款
     * @dev 需要 Guardian 和治理双重批准才能执行
     */
    function approveEmergencyWithdraw() external {
        require(msg.sender == guardian, "Only guardian");
        require(pendingEmergencyWithdraw.exists, "No pending withdraw");
        require(!pendingEmergencyWithdraw.guardianApproved, "Already approved");

        pendingEmergencyWithdraw.guardianApproved = true;
        emit EmergencyWithdrawApproved(msg.sender, true);
    }

    function cancelEmergencyWithdraw() external onlyOwner onlyGovernanceOwner onlyGovernanceExecutionContext {
        require(pendingEmergencyWithdraw.exists, "No pending withdraw");
        delete pendingEmergencyWithdraw;
        emit EmergencyWithdrawCancelled();
    }

    function executeEmergencyWithdraw() external {
        require(msg.sender == guardian || msg.sender == owner(), "Unauthorized");
        require(pendingEmergencyWithdraw.exists, "No pending withdraw");

        // 双重批准检查 (在时间锁检查之前)
        require(pendingEmergencyWithdraw.guardianApproved, "Guardian approval required");
        require(pendingEmergencyWithdraw.ownerApproved, "Owner approval required");

        // 时间锁检查
        require(block.timestamp >= pendingEmergencyWithdraw.executeAfter, "Timelock not expired");

        if (!pendingEmergencyWithdraw.guardianApproved || !pendingEmergencyWithdraw.ownerApproved) {
            revert EmergencyWithdrawNotFullyApproved();
        }

        PendingEmergencyWithdraw memory req = pendingEmergencyWithdraw;
        delete pendingEmergencyWithdraw;

        if (req.token == address(0)) {
            (bool success, ) = payable(req.to).call{value: req.amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(req.token).safeTransfer(req.to, req.amount);
        }
        emit EmergencyWithdraw(req.token, req.to, req.amount);
    }

    receive() external payable {}
}
