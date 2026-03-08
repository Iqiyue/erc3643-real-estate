// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/utils/Pausable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../token/RealEstateToken.sol";

/**
 * @title RealEstateDividendDistributor
 * @dev 基于快照的租金收益分配系统
 */
contract RealEstateDividendDistributor is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    RealEstateToken public token;

    struct Snapshot {
        address paymentToken;   // 20 bytes
        bool finalized;         // 1 byte
        uint256 snapshotId;     // 32 bytes (新槽)
        uint256 totalSupply;    // 32 bytes (新槽)
        uint256 dividendAmount; // 32 bytes (新槽)
        uint256 timestamp;      // 32 bytes (新槽)
    }

    mapping(uint256 => Snapshot) public snapshots;
    mapping(uint256 => mapping(address => uint256)) public snapshotBalances;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public currentSnapshotId;
    uint256 public activeSnapshotId;
    uint256 public nextSnapshotIndex;
    bool public snapshotsEnabled = true;

    event SnapshotCreated(uint256 indexed snapshotId, uint256 totalSupply, uint256 dividendAmount, address paymentToken);
    event DividendClaimed(uint256 indexed snapshotId, address indexed investor, uint256 amount);
    event DividendDistributed(uint256 indexed snapshotId, address indexed investor, uint256 amount);
    event SnapshotsEnabledSet(bool enabled);

    // 常量定义
    uint256 public constant MAX_BATCH_SIZE = 100;

    constructor(address _token) Ownable(msg.sender) {
        token = RealEstateToken(_token);
    }

    /**
     * @notice 创建快照(ETH 分红) - 分批处理
     * @param startIndex 开始索引
     * @param batchSize 批次大小
     * @return snapshotId 快照 ID
     * @return isComplete 是否完成
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function createSnapshotETH(uint256 startIndex, uint256 batchSize)
        external
        payable
        onlyOwner
        returns (uint256 snapshotId, bool isComplete)
    {
        require(snapshotsEnabled, "Snapshots disabled");
        require(token.paused(), "Token must be paused for snapshot");
        require(batchSize <= MAX_BATCH_SIZE, "Batch size too large");

        address[] memory investors = token.getInvestors();

        // 第一次调用,创建快照
        if (startIndex == 0) {
            require(activeSnapshotId == 0, "Snapshot in progress");
            require(msg.value > 0, "No ETH provided");

            currentSnapshotId++;
            Snapshot storage snapshot = snapshots[currentSnapshotId];
            snapshot.snapshotId = currentSnapshotId;
            snapshot.totalSupply = token.totalSupply();
            snapshot.dividendAmount = msg.value;
            snapshot.paymentToken = address(0);
            snapshot.timestamp = block.timestamp;
            snapshot.finalized = false;
            activeSnapshotId = currentSnapshotId;
            nextSnapshotIndex = 0;
        } else {
            require(activeSnapshotId != 0, "No active snapshot");
            require(msg.value == 0, "ETH not allowed in continuation");
        }

        require(activeSnapshotId == currentSnapshotId, "Invalid active snapshot");
        require(startIndex == nextSnapshotIndex, "Invalid batch start index");

        // 分批记录余额
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > investors.length) {
            endIndex = investors.length;
        }

        for (uint256 i = startIndex; i < endIndex; i++) {
            snapshotBalances[currentSnapshotId][investors[i]] = token.balanceOf(investors[i]);
        }

        nextSnapshotIndex = endIndex;
        isComplete = (endIndex >= investors.length);

        if (isComplete) {
            snapshots[currentSnapshotId].finalized = true;
            activeSnapshotId = 0;
            nextSnapshotIndex = 0;
            emit SnapshotCreated(
                currentSnapshotId,
                snapshots[currentSnapshotId].totalSupply,
                snapshots[currentSnapshotId].dividendAmount,
                address(0)
            );
        }

        return (currentSnapshotId, isComplete);
    }

    /**
     * @dev 创建快照(ERC20 代币分红)
     * @dev MEDIUM-2 修复: 添加投资者数量限制,防止 gas 耗尽
     */
    function createSnapshotERC20(address _paymentToken, uint256 _amount) external onlyOwner returns (uint256) {
        require(snapshotsEnabled, "Snapshots disabled");
        require(token.paused(), "Token must be paused for snapshot");
        require(activeSnapshotId == 0, "Snapshot in progress");
        require(_paymentToken != address(0), "Invalid payment token");
        require(_amount > 0, "No amount provided");

        address[] memory investors = token.getInvestors();
        // MEDIUM-2 修复: 限制投资者数量,防止 gas 耗尽
        require(investors.length <= 1000, "Too many investors, use createSnapshotETH with batching");

        IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), _amount);

        currentSnapshotId++;
        Snapshot storage snapshot = snapshots[currentSnapshotId];

        snapshot.snapshotId = currentSnapshotId;
        snapshot.totalSupply = token.totalSupply();
        snapshot.dividendAmount = _amount;
        snapshot.paymentToken = _paymentToken;
        snapshot.timestamp = block.timestamp;
        snapshot.finalized = true;

        for (uint256 i = 0; i < investors.length; i++) {
            snapshotBalances[currentSnapshotId][investors[i]] = token.balanceOf(investors[i]);
        }

        emit SnapshotCreated(currentSnapshotId, snapshot.totalSupply, _amount, _paymentToken);
        return currentSnapshotId;
    }

    /**
     * @dev 投资者领取分红
     */
    function claimDividend(uint256 _snapshotId) external nonReentrant whenNotPaused {
        Snapshot storage snapshot = snapshots[_snapshotId];
        require(snapshot.snapshotId != 0, "Snapshot does not exist");
        require(snapshot.finalized, "Snapshot not finalized");
        require(!claimed[_snapshotId][msg.sender], "Already claimed");
        require(snapshotBalances[_snapshotId][msg.sender] > 0, "No balance in snapshot");

        uint256 dividend = calculateDividend(_snapshotId, msg.sender);
        require(dividend > 0, "No dividend to claim");

        claimed[_snapshotId][msg.sender] = true;

        if (snapshot.paymentToken == address(0)) {
            (bool success, ) = msg.sender.call{value: dividend}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(snapshot.paymentToken).safeTransfer(msg.sender, dividend);
        }

        emit DividendClaimed(_snapshotId, msg.sender, dividend);
    }

    /**
     * @dev 批量领取多个快照的分红
     */
    function claimMultipleDividends(uint256[] calldata _snapshotIds) external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < _snapshotIds.length; i++) {
            uint256 snapshotId = _snapshotIds[i];
            Snapshot storage snapshot = snapshots[snapshotId];

            if (
                snapshot.snapshotId == 0 ||
                !snapshot.finalized ||
                claimed[snapshotId][msg.sender] ||
                snapshotBalances[snapshotId][msg.sender] == 0
            ) {
                continue;
            }

            uint256 dividend = calculateDividend(snapshotId, msg.sender);
            if (dividend == 0) {
                continue;
            }

            claimed[snapshotId][msg.sender] = true;

            if (snapshot.paymentToken == address(0)) {
                (bool success, ) = msg.sender.call{value: dividend}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(snapshot.paymentToken).safeTransfer(msg.sender, dividend);
            }

            emit DividendClaimed(snapshotId, msg.sender, dividend);
        }
    }

    /**
     * @dev 管理员批量分发分红(推送式)
     */
    /**
     * @dev 管理员批量分发分红(推送式)
     * @dev HIGH-3 修复: 使用低 gas 限制防止恶意合约 DoS
     */
    function batchDistribute(uint256 _snapshotId, address[] calldata _investors) external onlyOwner nonReentrant whenNotPaused {
        Snapshot storage snapshot = snapshots[_snapshotId];
        require(snapshot.snapshotId != 0, "Snapshot does not exist");
        require(snapshot.finalized, "Snapshot not finalized");
        require(_investors.length > 0, "Empty array"); // LOW-8: 数组长度验证
        require(_investors.length <= 100, "Batch size too large"); // LOW-8: 限制批量大小

        for (uint256 i = 0; i < _investors.length; i++) {
            address investor = _investors[i];

            if (claimed[_snapshotId][investor] || snapshotBalances[_snapshotId][investor] == 0) {
                continue;
            }

            uint256 dividend = calculateDividend(_snapshotId, investor);
            if (dividend == 0) {
                continue;
            }

            // Checks-Effects-Interactions: 先更新状态
            claimed[_snapshotId][investor] = true;

            // Interactions: 最后执行外部调用
            if (snapshot.paymentToken == address(0)) {
                // HIGH-3 修复: 限制 gas 为 2300,防止恶意合约消耗大量 gas
                (bool success, ) = investor.call{value: dividend, gas: 2300}("");
                if (success) {
                    emit DividendDistributed(_snapshotId, investor, dividend);
                } else {
                    // 失败时回滚状态,允许用户自己领取
                    claimed[_snapshotId][investor] = false;
                }
            } else {
                // ERC20 转账已经使用 safeTransfer,有内置保护
                IERC20(snapshot.paymentToken).safeTransfer(investor, dividend);
                emit DividendDistributed(_snapshotId, investor, dividend);
            }
        }
    }

    /**
     * @dev 计算投资者的分红金额
     */
    function calculateDividend(uint256 _snapshotId, address _investor) public view returns (uint256) {
        Snapshot storage snapshot = snapshots[_snapshotId];
        if (snapshot.snapshotId == 0 || snapshot.totalSupply == 0) {
            return 0;
        }

        uint256 balance = snapshotBalances[_snapshotId][_investor];
        if (balance == 0) {
            return 0;
        }

        return (snapshot.dividendAmount * balance) / snapshot.totalSupply;
    }

    /**
     * @dev 查询未领取的分红
     */
    function getUnclaimedDividend(uint256 _snapshotId, address _investor) external view returns (uint256) {
        if (claimed[_snapshotId][_investor]) {
            return 0;
        }
        return calculateDividend(_snapshotId, _investor);
    }

    /**
     * @dev 查询是否已领取
     */
    function hasClaimed(uint256 _snapshotId, address _investor) external view returns (bool) {
        return claimed[_snapshotId][_investor];
    }

    /**
     * @dev 获取快照信息
     */
    function getSnapshotInfo(uint256 _snapshotId)
        external
        view
        returns (
            uint256 snapshotId,
            uint256 totalSupply,
            uint256 dividendAmount,
            address paymentToken,
            uint256 timestamp,
            bool finalized
        )
    {
        Snapshot storage snapshot = snapshots[_snapshotId];
        return (
            snapshot.snapshotId,
            snapshot.totalSupply,
            snapshot.dividendAmount,
            snapshot.paymentToken,
            snapshot.timestamp,
            snapshot.finalized
        );
    }

    /**
     * @dev 获取投资者在快照中的余额
     */
    function getSnapshotBalance(uint256 _snapshotId, address _investor) external view returns (uint256) {
        return snapshotBalances[_snapshotId][_investor];
    }

    function setSnapshotsEnabled(bool enabled) external onlyOwner {
        snapshotsEnabled = enabled;
        emit SnapshotsEnabledSet(enabled);
    }

    /**
     * @dev 暂停分红领取
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev 恢复分红领取
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}
