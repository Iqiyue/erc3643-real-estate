// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/identity/Identity.sol";
import "../../src/identity/IdentityFactory.sol";
import "../../src/identity/ClaimIssuer.sol";
import "../../src/identity/IdentityRegistryStorage.sol";
import "../../src/identity/IdentityRegistry.sol";
import "../../src/compliance/ModularCompliance.sol";
import "../../src/token/RealEstateToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title RealEstateTokenV2
 * @dev 升级后的代币合约 (用于测试)
 */
contract RealEstateTokenV2 is RealEstateToken {
    // 新增状态变量
    uint256 public newFeature;

    /**
     * @dev 新增功能: 设置新特性
     */
    function setNewFeature(uint256 _value) external onlyOwner {
        newFeature = _value;
    }

    /**
     * @dev 返回版本号
     */
    function version() external pure returns (string memory) {
        return "v2.0.0";
    }
}

/**
 * @title UUPSUpgradeTest
 * @dev 测试 UUPS 代理升级流程
 */
contract UUPSUpgradeTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityFactory public identityFactory;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;
    RealEstateTokenV2 public tokenV2Implementation;

    address public owner;
    address public agent;
    address public investor1;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        agent = makeAddr("agent");
        investor1 = makeAddr("investor1");
        issuerOwner = vm.addr(issuerPrivateKey);

        // 部署 V1
        vm.prank(issuerOwner);
        claimIssuer = new ClaimIssuer();
        Identity identityImplementation = new Identity(address(0));
        identityFactory = new IdentityFactory(address(identityImplementation));
        identityStorage = new IdentityRegistryStorage();

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
        compliance = new ModularCompliance();

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
        token.addAgent(agent);

        // 部署 V2 实现
        tokenV2Implementation = new RealEstateTokenV2();
    }

    /**
     * @dev 测试完整的升级流程
     */
    function testCompleteUpgradeFlow() public {
        // 注册投资者并铸造代币
        _registerInvestor(investor1, 840);

        vm.prank(agent);
        token.mint(investor1, 1000 ether);

        uint256 balanceBefore = token.balanceOf(investor1);
        assertEq(balanceBefore, 1000 ether);

        // ============ 阶段 1: 调度升级 ============
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 验证升级已调度
        (
            address scheduledImpl,
            bool executed,
            bool cancelled,
            uint256 scheduledTime,
        ) = token.pendingUpgrade();

        assertEq(scheduledImpl, address(tokenV2Implementation));
        assertFalse(executed);
        assertFalse(cancelled);
        assertEq(scheduledTime, block.timestamp + 7 days);

        // ============ 阶段 2: 等待时间锁 ============
        // 尝试在时间锁期间执行 (应该失败)
        vm.expectRevert();
        token.executeUpgrade();

        // 跳过时间锁
        vm.warp(block.timestamp + 7 days + 1);

        // ============ 阶段 3: 执行升级 ============
        token.executeUpgrade();

        // 验证升级成功
        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));

        // 验证状态保留
        assertEq(upgradedToken.balanceOf(investor1), balanceBefore);
        assertEq(upgradedToken.name(), "Real Estate Token");
        assertEq(upgradedToken.symbol(), "RET");

        // 验证新功能可用
        assertEq(upgradedToken.version(), "v2.0.0");

        upgradedToken.setNewFeature(42);
        assertEq(upgradedToken.newFeature(), 42);

        // 验证旧功能仍然工作
        vm.warp(block.timestamp + 2 minutes);
        vm.prank(agent);
        upgradedToken.mint(investor1, 500 ether);

        assertEq(upgradedToken.balanceOf(investor1), 1500 ether);
    }

    /**
     * @dev 测试升级时间锁保护
     */
    function testUpgradeTimelockProtection() public {
        // 调度升级
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 尝试立即执行 (应该失败)
        vm.expectRevert();
        token.executeUpgrade();

        // 尝试在时间锁期间执行 (应该失败)
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert();
        token.executeUpgrade();

        // 时间锁过期后可以执行
        vm.warp(block.timestamp + 1 days + 1);
        token.executeUpgrade();
    }

    /**
     * @dev 测试升级有效期
     */
    function testUpgradeExpiry() public {
        // 调度升级
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 跳过时间锁 + 有效期
        vm.warp(block.timestamp + 7 days + 7 days + 1);

        // 尝试执行过期的升级 (应该失败)
        vm.expectRevert();
        token.executeUpgrade();
    }

    /**
     * @dev 测试取消升级
     */
    function testCancelUpgrade() public {
        // 调度升级
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 取消升级
        token.cancelUpgrade();

        // 验证升级已取消
        (
            ,
            ,
            bool cancelled,
            ,
        ) = token.pendingUpgrade();

        assertTrue(cancelled);

        // 尝试执行已取消的升级 (应该失败)
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert();
        token.executeUpgrade();
    }

    /**
     * @dev 测试重新调度升级
     */
    function testRescheduleUpgrade() public {
        // 第一次调度
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 取消
        token.cancelUpgrade();

        // 等待冷却期
        vm.warp(block.timestamp + 2 days + 1);

        // 重新调度
        RealEstateTokenV2 newImplementation = new RealEstateTokenV2();
        token.scheduleUpgrade(address(newImplementation));

        // 执行新的升级
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));
        assertEq(upgradedToken.version(), "v2.0.0");
    }

    /**
     * @dev 测试未经调度直接升级 (应该失败)
     */
    function testDirectUpgradeWithoutScheduling() public {
        vm.expectRevert();
        token.executeUpgrade();
    }

    /**
     * @dev 测试重复执行升级 (应该失败)
     */
    function testDoubleUpgradeExecution() public {
        // 调度并执行升级
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        // 尝试再次执行 (应该失败)
        vm.expectRevert();
        token.executeUpgrade();
    }

    /**
     * @dev 测试非 owner 尝试升级 (应该失败)
     */
    function testUnauthorizedUpgrade() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        token.scheduleUpgrade(address(tokenV2Implementation));
    }

    /**
     * @dev 测试升级到零地址 (应该失败)
     */
    function testUpgradeToZeroAddress() public {
        vm.expectRevert();
        token.scheduleUpgrade(address(0));
    }

    /**
     * @dev 测试升级后存储槽兼容性
     */
    function testStorageSlotCompatibility() public {
        // 设置一些状态
        _registerInvestor(investor1, 840);

        vm.prank(agent);
        token.mint(investor1, 1000 ether);

        token.addAgent(agent);
        address guardian = makeAddr("guardian");
        token.setGuardian(guardian);

        // 记录升级前的状态
        uint256 balanceBefore = token.balanceOf(investor1);
        address agentBefore = agent;
        address guardianBefore = guardian;
        address identityRegistryBefore = address(token.identityRegistry());
        address complianceBefore = address(token.compliance());

        // 执行升级
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));

        // 验证所有状态都保留
        assertEq(upgradedToken.balanceOf(investor1), balanceBefore);
        assertTrue(upgradedToken.isAgent(agentBefore));
        assertEq(upgradedToken.guardian(), guardianBefore);
        assertEq(address(upgradedToken.identityRegistry()), identityRegistryBefore);
        assertEq(address(upgradedToken.compliance()), complianceBefore);
    }

    /**
     * @dev 测试升级后功能完整性
     */
    function testFunctionalityAfterUpgrade() public {
        // 注册投资者
        _registerInvestor(investor1, 840);
        address investor2 = makeAddr("investor2");
        _registerInvestor(investor2, 840);

        // 升级前铸造
        vm.prank(agent);
        token.mint(investor1, 1000 ether);

        // 执行升级
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));

        // 测试升级后的铸造
        vm.warp(block.timestamp + 2 minutes);
        vm.prank(agent);
        upgradedToken.mint(investor2, 500 ether);

        assertEq(upgradedToken.balanceOf(investor2), 500 ether);

        // 测试升级后的转账
        vm.prank(investor1);
        upgradedToken.transfer(investor2, 100 ether);

        assertEq(upgradedToken.balanceOf(investor1), 900 ether);
        assertEq(upgradedToken.balanceOf(investor2), 600 ether);

        // 测试升级后的销毁
        vm.prank(agent);
        upgradedToken.burn(investor1, 100 ether);

        assertEq(upgradedToken.balanceOf(investor1), 800 ether);
    }

    /**
     * @dev 辅助函数: 注册投资者
     */
    function _registerInvestor(address investor, uint16 country) internal {
        address identityAddr = identityFactory.createIdentity(investor);
        Identity identity = Identity(identityAddr);

        vm.prank(investor);
        identity.authorizeClaimIssuer(address(claimIssuer));

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = claimIssuer.getSignedClaim(identityAddr, 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(investor);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, identityAddr, country);
    }
}

/**
 * @title UpgradeRollbackTest
 * @dev 测试升级回滚场景
 */
contract UpgradeRollbackTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;
    RealEstateTokenV2 public tokenV2Implementation;

    address public owner;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        issuerOwner = vm.addr(issuerPrivateKey);

        vm.prank(issuerOwner);
        claimIssuer = new ClaimIssuer();
        identityStorage = new IdentityRegistryStorage();

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
        compliance = new ModularCompliance();

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

        tokenV2Implementation = new RealEstateTokenV2();
    }

    /**
     * @dev 测试升级后回滚到 V1
     */
    function testUpgradeAndRollback() public {
        // 升级到 V2
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));
        assertEq(upgradedToken.version(), "v2.0.0");

        // 设置 V2 的新特性
        upgradedToken.setNewFeature(42);
        assertEq(upgradedToken.newFeature(), 42);

        // 回滚到 V1
        RealEstateToken v1Implementation = new RealEstateToken();
        upgradedToken.scheduleUpgrade(address(v1Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        upgradedToken.executeUpgrade();

        // 验证回滚成功 (V2 的新功能不再可用)
        // 注意: 新状态变量的值仍然存在于存储中,但无法访问
    }
}
