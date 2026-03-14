// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/distribution/RealEstateDividendDistributor.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/token/RealEstateToken.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/Identity.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/ClaimIssuer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityRegistryStorage.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DividendDistributorTest is Test {
    RealEstateToken public token;
    RealEstateDividendDistributor public distributor;
    MockUSDC public usdc;

    ClaimIssuer public claimIssuer;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;

    address public owner;
    address public investor1;
    address public investor2;
    address public investor3;
    address public issuerOwner;  // ClaimIssuer 的所有者
    uint256 public issuerPrivateKey = 1;  // 私钥

    function setUp() public {
        owner = address(this);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
        investor3 = makeAddr("investor3");
        issuerOwner = vm.addr(issuerPrivateKey);  // 从私钥生成地址

        // 部署身份系统
        vm.prank(issuerOwner);  // 使用 issuerOwner 部署 ClaimIssuer
        claimIssuer = new ClaimIssuer();
        IdentityRegistryStorage identityStorage = new IdentityRegistryStorage();

        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;

        identityRegistry = new IdentityRegistry(
            address(identityStorage),
            trustedIssuers,
            claimTopics
        );

        identityStorage.bindIdentityRegistry(address(identityRegistry));

        // 部署合规引擎
        compliance = new ModularCompliance();

        // 部署代币
        RealEstateToken tokenImplementation = new RealEstateToken();
        bytes memory initData = abi.encodeWithSelector(
            RealEstateToken.initialize.selector,
            "Real Estate Token",
            "RET",
            address(identityRegistry),
            address(compliance)
        );

        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImplementation), initData);
        token = RealEstateToken(address(tokenProxy));

        compliance.bindToken(address(token));
        token.addAgent(owner);

        // 部署分红分配器
        distributor = new RealEstateDividendDistributor(address(token));

        // 部署 Mock USDC
        usdc = new MockUSDC();

        // 注册投资者
        _registerInvestor(investor1);
        _registerInvestor(investor2);
        _registerInvestor(investor3);

        // 分配代币
        token.mint(investor1, 5000 ether); // 50%
        token.mint(investor2, 3000 ether); // 30%
        token.mint(investor3, 2000 ether); // 20%

        // 给测试账户一些 ETH
        vm.deal(owner, 100 ether);
    }

    function testCreateETHSnapshot() public {
        token.pause();
        // 使用新的分批 API
        (uint256 snapshotId, bool isComplete) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        assertEq(snapshotId, 1);
        assertTrue(isComplete); // 只有3个投资者,应该一次完成

        (
            uint256 id,
            uint256 totalSupply,
            uint256 dividendAmount,
            address paymentToken,
            uint256 timestamp,
            bool finalized
        ) = distributor.getSnapshotInfo(snapshotId);

        assertEq(id, 1);
        assertEq(totalSupply, 10000 ether);
        assertEq(dividendAmount, 10 ether);
        assertEq(paymentToken, address(0));
        assertGt(timestamp, 0);
        assertTrue(finalized);
    }

    function testCreateERC20Snapshot() public {
        usdc.approve(address(distributor), 1000 ether);
        token.pause();
        uint256 snapshotId = distributor.createSnapshotERC20(address(usdc), 1000 ether);
        token.unpause();

        assertEq(snapshotId, 1);

        (,, uint256 dividendAmount, address paymentToken,, bool finalized) = distributor.getSnapshotInfo(snapshotId);

        assertEq(dividendAmount, 1000 ether);
        assertEq(paymentToken, address(usdc));
        assertTrue(finalized);
    }

    function testCreateETHSnapshotBatchStateMachine() public {
        token.pause();
        (uint256 snapshotId, bool complete1) = distributor.createSnapshotETH{value: 10 ether}(0, 1);
        assertEq(snapshotId, 1);
        assertFalse(complete1);

        vm.expectRevert("ETH not allowed in continuation");
        distributor.createSnapshotETH{value: 1 ether}(1, 1);

        vm.expectRevert("Snapshot in progress");
        distributor.createSnapshotETH(0, 1);

        (, bool complete2) = distributor.createSnapshotETH(1, 1);
        assertFalse(complete2);

        (, bool complete3) = distributor.createSnapshotETH(2, 1);
        assertTrue(complete3);

        vm.expectRevert("No active snapshot");
        distributor.createSnapshotETH(1, 1);
        token.unpause();
    }

    function testCalculateDividend() public {
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        // investor1 持有 50%, 应得 5 ETH
        uint256 dividend1 = distributor.calculateDividend(snapshotId, investor1);
        assertEq(dividend1, 5 ether);

        // investor2 持有 30%, 应得 3 ETH
        uint256 dividend2 = distributor.calculateDividend(snapshotId, investor2);
        assertEq(dividend2, 3 ether);

        // investor3 持有 20%, 应得 2 ETH
        uint256 dividend3 = distributor.calculateDividend(snapshotId, investor3);
        assertEq(dividend3, 2 ether);
    }

    function testClaimETHDividend() public {
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        uint256 balanceBefore = investor1.balance;

        vm.prank(investor1);
        distributor.claimDividend(snapshotId);

        uint256 balanceAfter = investor1.balance;

        assertEq(balanceAfter - balanceBefore, 5 ether);
        assertTrue(distributor.hasClaimed(snapshotId, investor1));
    }

    function testClaimERC20Dividend() public {
        usdc.approve(address(distributor), 1000 ether);
        token.pause();
        uint256 snapshotId = distributor.createSnapshotERC20(address(usdc), 1000 ether);
        token.unpause();

        uint256 balanceBefore = usdc.balanceOf(investor1);

        vm.prank(investor1);
        distributor.claimDividend(snapshotId);

        uint256 balanceAfter = usdc.balanceOf(investor1);

        assertEq(balanceAfter - balanceBefore, 500 ether); // 50%
        assertTrue(distributor.hasClaimed(snapshotId, investor1));
    }

    function testCannotClaimTwice() public {
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        vm.startPrank(investor1);
        distributor.claimDividend(snapshotId);

        vm.expectRevert("Already claimed");
        distributor.claimDividend(snapshotId);
        vm.stopPrank();
    }

    function testClaimMultipleDividends() public {
        // 创建多个快照
        token.pause();
        (uint256 snapshot1,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        (uint256 snapshot2,) = distributor.createSnapshotETH{value: 5 ether}(0, 100);
        token.unpause();

        uint256[] memory snapshotIds = new uint256[](2);
        snapshotIds[0] = snapshot1;
        snapshotIds[1] = snapshot2;

        uint256 balanceBefore = investor1.balance;

        vm.prank(investor1);
        distributor.claimMultipleDividends(snapshotIds);

        uint256 balanceAfter = investor1.balance;

        // 应该收到两次分红: 5 ETH + 2.5 ETH = 7.5 ETH
        assertEq(balanceAfter - balanceBefore, 7.5 ether);
    }

    function testBatchDistribute() public {
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;

        uint256 balance1Before = investor1.balance;
        uint256 balance2Before = investor2.balance;

        distributor.batchDistribute(snapshotId, investors);

        assertEq(investor1.balance - balance1Before, 5 ether);
        assertEq(investor2.balance - balance2Before, 3 ether);
    }

    function testSnapshotAfterTransfer() public {
        // 创建快照
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        // 快照后转账不影响分红
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 1000 ether));

        // investor1 仍然应该得到 5 ETH (基于快照时的余额)
        uint256 dividend1 = distributor.calculateDividend(snapshotId, investor1);
        assertEq(dividend1, 5 ether);
    }

    function testGetUnclaimedDividend() public {
        token.pause();
        (uint256 snapshotId,) = distributor.createSnapshotETH{value: 10 ether}(0, 100);
        token.unpause();

        uint256 unclaimed = distributor.getUnclaimedDividend(snapshotId, investor1);
        assertEq(unclaimed, 5 ether);

        vm.prank(investor1);
        distributor.claimDividend(snapshotId);

        unclaimed = distributor.getUnclaimedDividend(snapshotId, investor1);
        assertEq(unclaimed, 0);
    }

    // 辅助函数
    function _registerInvestor(address investor) internal {
        Identity identity = new Identity(investor);

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // HIGH-2 修复: 添加受信任的签发者
        vm.prank(investor);
        identity.authorizeClaimIssuer(address(claimIssuer));

        vm.prank(investor);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), 840);
    }
}
