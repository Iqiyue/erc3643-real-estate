// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/distribution/MerkleTreeDividendDistributor.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1000000 ether);
    }
}

contract GovernanceExecutionContextMock {
    bytes32 public currentExecutionHash;

    function execute(address target, bytes calldata data) external {
        currentExecutionHash = keccak256(abi.encode(target, data, uint256(0)));
        (bool ok, ) = target.call(data);
        require(ok, "governance execution failed");
        currentExecutionHash = bytes32(0);
    }
}

/**
 * @title MerkleTreeDividendDistributorTest
 * @notice 测试 Merkle Tree + Bitmap 分红系统
 */
contract MerkleTreeDividendDistributorTest is Test {
    MerkleTreeDividendDistributor public distributor;
    MockToken public token;
    GovernanceExecutionContextMock public governance;

    address public owner;
    address public investor1;
    address public investor2;
    address public investor3;

    function setUp() public {
        owner = address(this);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
        investor3 = makeAddr("investor3");

        distributor = new MerkleTreeDividendDistributor();
        token = new MockToken();
        governance = new GovernanceExecutionContextMock();

        vm.deal(owner, 100 ether);
    }

    /**
     * @notice 测试 Bitmap 基本操作
     */
    function testBitmapOperations() public {
        // 创建一个简单的快照
        bytes32 merkleRoot = keccak256("test");
        uint256 snapshotId = distributor.createSnapshot{value: 10 ether}(
            merkleRoot,
            10 ether,
            address(0),
            1000 // 1000 个投资者
        );

        // 测试 Bitmap 计算
        uint256 slots = distributor.calculateBitmapSlots(1000);
        assertEq(slots, 4); // 1000 / 256 = 3.9 -> 4 个槽位

        // 测试领取状态查询
        assertFalse(distributor.hasClaimed(snapshotId, 0));
        assertFalse(distributor.hasClaimed(snapshotId, 255));
        assertFalse(distributor.hasClaimed(snapshotId, 256));
        assertFalse(distributor.hasClaimed(snapshotId, 999));
    }

    /**
     * @notice 测试 ETH 分红领取
     */
    function testClaimETHDividend() public {
        // 构建 Merkle Tree
        // Leaf 0: investor1, 5 ether
        // Leaf 1: investor2, 3 ether
        // Leaf 2: investor3, 2 ether

        bytes32 leaf0 = keccak256(abi.encodePacked(uint256(0), investor1, uint256(5 ether)));
        bytes32 leaf1 = keccak256(abi.encodePacked(uint256(1), investor2, uint256(3 ether)));
        bytes32 leaf2 = keccak256(abi.encodePacked(uint256(2), investor3, uint256(2 ether)));

        // 构建 Merkle Tree (简化版,实际应使用标准 Merkle Tree 库)
        bytes32 node01 = _hashPair(leaf0, leaf1);
        bytes32 root = _hashPair(node01, leaf2);

        // 创建快照
        uint256 snapshotId = distributor.createSnapshot{value: 10 ether}(
            root,
            10 ether,
            address(0),
            3
        );

        // investor1 领取分红
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf1;
        proof1[1] = leaf2;

        uint256 balanceBefore = investor1.balance;

        vm.prank(investor1);
        distributor.claimDividend(snapshotId, 0, 5 ether, proof1);

        uint256 balanceAfter = investor1.balance;
        assertEq(balanceAfter - balanceBefore, 5 ether);

        // 验证已标记为领取
        assertTrue(distributor.hasClaimed(snapshotId, 0));

        // 尝试重复领取应该失败
        vm.prank(investor1);
        vm.expectRevert("Already claimed");
        distributor.claimDividend(snapshotId, 0, 5 ether, proof1);
    }

    /**
     * @notice 测试 ERC20 分红领取
     */
    function testClaimERC20Dividend() public {
        bytes32 leaf0 = keccak256(abi.encodePacked(uint256(0), investor1, uint256(500 ether)));
        bytes32 root = leaf0; // 单个投资者,root = leaf

        token.approve(address(distributor), 500 ether);

        uint256 snapshotId = distributor.createSnapshot(
            root,
            500 ether,
            address(token),
            1
        );

        bytes32[] memory proof = new bytes32[](0); // 单个叶子不需要 proof

        uint256 balanceBefore = token.balanceOf(investor1);

        vm.prank(investor1);
        distributor.claimDividend(snapshotId, 0, 500 ether, proof);

        uint256 balanceAfter = token.balanceOf(investor1);
        assertEq(balanceAfter - balanceBefore, 500 ether);
    }

    /**
     * @notice 测试批量领取
     */
    function testClaimMultipleDividends() public {
        // 创建两个快照
        bytes32 leaf0Snap1 = keccak256(abi.encodePacked(uint256(0), investor1, uint256(5 ether)));
        bytes32 root1 = leaf0Snap1;

        bytes32 leaf0Snap2 = keccak256(abi.encodePacked(uint256(0), investor1, uint256(3 ether)));
        bytes32 root2 = leaf0Snap2;

        uint256 snapshot1 = distributor.createSnapshot{value: 5 ether}(root1, 5 ether, address(0), 1);
        uint256 snapshot2 = distributor.createSnapshot{value: 3 ether}(root2, 3 ether, address(0), 1);

        // 批量领取
        uint256[] memory snapshotIds = new uint256[](2);
        snapshotIds[0] = snapshot1;
        snapshotIds[1] = snapshot2;

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 0;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5 ether;
        amounts[1] = 3 ether;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        uint256 balanceBefore = investor1.balance;

        vm.prank(investor1);
        distributor.claimMultipleDividends(snapshotIds, indices, amounts, proofs);

        uint256 balanceAfter = investor1.balance;
        assertEq(balanceAfter - balanceBefore, 8 ether);

        assertTrue(distributor.hasClaimed(snapshot1, 0));
        assertTrue(distributor.hasClaimed(snapshot2, 0));
    }

    /**
     * @notice 测试 Bitmap 压缩效率
     */
    function testBitmapCompression() public {
        bytes32 root = keccak256("test");

        // 测试 1000 个投资者
        uint256 snapshotId = distributor.createSnapshot{value: 10 ether}(
            root,
            10 ether,
            address(0),
            1000
        );

        // 需要 4 个 bitmap 槽位 (1000 / 256 = 4)
        assertEq(distributor.calculateBitmapSlots(1000), 4);

        // 验证不同范围的索引
        assertFalse(distributor.hasClaimed(snapshotId, 0));    // 第 1 个槽位
        assertFalse(distributor.hasClaimed(snapshotId, 255));  // 第 1 个槽位
        assertFalse(distributor.hasClaimed(snapshotId, 256));  // 第 2 个槽位
        assertFalse(distributor.hasClaimed(snapshotId, 511));  // 第 2 个槽位
        assertFalse(distributor.hasClaimed(snapshotId, 512));  // 第 3 个槽位
        assertFalse(distributor.hasClaimed(snapshotId, 999));  // 第 4 个槽位
    }

    /**
     * @notice 测试批量查询领取状态
     */
    function testBatchCheckClaimed() public {
        bytes32 root = keccak256("test");
        uint256 snapshotId = distributor.createSnapshot{value: 10 ether}(
            root,
            10 ether,
            address(0),
            10
        );

        uint256[] memory indices = new uint256[](5);
        indices[0] = 0;
        indices[1] = 1;
        indices[2] = 2;
        indices[3] = 3;
        indices[4] = 4;

        bool[] memory results = distributor.batchCheckClaimed(snapshotId, indices);

        for (uint256 i = 0; i < results.length; i++) {
            assertFalse(results[i]);
        }
    }

    /**
     * @notice 测试获取完整 Bitmap
     */
    function testGetBitmap() public {
        bytes32 root = keccak256("test");
        uint256 snapshotId = distributor.createSnapshot{value: 10 ether}(
            root,
            10 ether,
            address(0),
            256
        );

        // 初始状态应该是 0
        uint256 bitmap = distributor.getBitmap(snapshotId, 0);
        assertEq(bitmap, 0);
    }

    /**
     * @notice 测试无效的 Merkle Proof
     */
    function testInvalidMerkleProof() public {
        bytes32 leaf = keccak256(abi.encodePacked(uint256(0), investor1, uint256(5 ether)));
        bytes32 root = leaf;

        uint256 snapshotId = distributor.createSnapshot{value: 5 ether}(
            root,
            5 ether,
            address(0),
            1
        );

        // 使用错误的金额
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(investor1);
        vm.expectRevert("Invalid merkle proof");
        distributor.claimDividend(snapshotId, 0, 10 ether, proof); // 错误金额
    }

    function testRevertWhen_InvalidInvestorIndexInBatchClaim() public {
        bytes32 leaf0 = keccak256(abi.encodePacked(uint256(0), investor1, uint256(5 ether)));
        uint256 snapshotId = distributor.createSnapshot{value: 5 ether}(leaf0, 5 ether, address(0), 1);

        uint256[] memory snapshotIds = new uint256[](1);
        snapshotIds[0] = snapshotId;

        uint256[] memory indices = new uint256[](1);
        indices[0] = 1; // out of range

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5 ether;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(investor1);
        vm.expectRevert("Invalid investor index");
        distributor.claimMultipleDividends(snapshotIds, indices, amounts, proofs);
    }

    function testEmergencyWithdrawRequiresGuardianAndTimelock() public {
        address guardian = makeAddr("guardian");
        address recipient = makeAddr("recipient");
        vm.deal(address(distributor), 5 ether);

        distributor.transferOwnership(address(governance));
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(MerkleTreeDividendDistributor.setGuardian.selector, guardian)
        );
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(
                MerkleTreeDividendDistributor.scheduleEmergencyWithdraw.selector,
                address(0),
                recipient,
                1 ether
            )
        );

        // 测试: 非 guardian/owner 不能执行
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Unauthorized");
        distributor.executeEmergencyWithdraw();

        // 测试: Guardian 未批准不能执行
        vm.prank(guardian);
        vm.expectRevert("Guardian approval required");
        distributor.executeEmergencyWithdraw();

        // Guardian 批准
        vm.prank(guardian);
        distributor.approveEmergencyWithdraw();

        // 测试: 时间锁未到期不能执行
        vm.prank(guardian);
        vm.expectRevert("Timelock not expired");
        distributor.executeEmergencyWithdraw();

        // 等待时间锁到期 (包括额外延迟)
        vm.warp(block.timestamp + distributor.EMERGENCY_WITHDRAW_DELAY() + distributor.EMERGENCY_ADDITIONAL_DELAY() + 1);
        uint256 beforeBal = recipient.balance;
        vm.prank(guardian);
        distributor.executeEmergencyWithdraw();
        assertEq(recipient.balance - beforeBal, 1 ether);
    }

    function testOwnerCanCancelEmergencyWithdraw() public {
        address guardian = makeAddr("guardian");
        address recipient = makeAddr("recipient");
        distributor.transferOwnership(address(governance));
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(MerkleTreeDividendDistributor.setGuardian.selector, guardian)
        );
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(
                MerkleTreeDividendDistributor.scheduleEmergencyWithdraw.selector,
                address(0),
                recipient,
                1 ether
            )
        );
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(MerkleTreeDividendDistributor.cancelEmergencyWithdraw.selector)
        );

        vm.warp(block.timestamp + distributor.EMERGENCY_WITHDRAW_DELAY() + 1);
        vm.prank(guardian);
        vm.expectRevert("No pending withdraw");
        distributor.executeEmergencyWithdraw();
    }

    /**
     * @notice 测试治理上下文要求
     * @dev 简化测试,只验证核心功能
     */
    function testEmergencyGovernanceContextRequired() public {
        address guardian = makeAddr("guardian");

        // 测试: 非治理合约不能调用 setGuardian
        vm.expectRevert();
        distributor.setGuardian(guardian);

        // 转移所有权到治理合约后,可以通过治理执行
        distributor.transferOwnership(address(governance));
        governance.execute(
            address(distributor),
            abi.encodeWithSelector(MerkleTreeDividendDistributor.setGuardian.selector, guardian)
        );

        // 验证 guardian 已设置
        assertEq(distributor.guardian(), guardian);
    }

    // ============ 辅助函数 ============

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
