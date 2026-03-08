// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
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

/**
 * @title RealEstateTokenV2
 * @dev 用于测试升级的新版本合约
 */
contract RealEstateTokenV2 is RealEstateToken {
    uint256 public newFeature;

    function setNewFeature(uint256 _value) external {
        newFeature = _value;
    }
}

/**
 * @title UpgradeTimelockTest
 * @dev 测试升级时间锁功能
 */
contract UpgradeTimelockTest is Test {
    RealEstateToken public token;
    RealEstateTokenV2 public tokenV2Implementation;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;

    address public owner;
    address public user1;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");

        // 部署身份系统
        ClaimIssuer claimIssuer = new ClaimIssuer();
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

        // 部署 V2 实现合约
        tokenV2Implementation = new RealEstateTokenV2();
    }

    /**
     * @dev 测试: 安排升级
     */
    function test_ScheduleUpgrade() public {
        address newImpl = address(tokenV2Implementation);

        token.scheduleUpgrade(newImpl);

        (address impl, bool executed, bool cancelled, uint256 scheduledTime,) = token.pendingUpgrade();
        assertEq(impl, newImpl);
        assertEq(scheduledTime, block.timestamp + 7 days);
        assertFalse(executed);
        assertFalse(cancelled);
    }

    /**
     * @dev 测试: 不能安排零地址升级
     */
    function test_RevertWhen_ScheduleUpgradeWithZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RealEstateToken.InvalidAddress.selector, address(0)));
        token.scheduleUpgrade(address(0));
    }

    /**
     * @dev 测试: 不能重复安排升级
     */
    function test_RevertWhen_ScheduleUpgradeTwice() public {
        token.scheduleUpgrade(address(tokenV2Implementation));

        vm.expectRevert(RealEstateToken.UpgradeAlreadyScheduled.selector);
        token.scheduleUpgrade(address(tokenV2Implementation));
    }

    /**
     * @dev 测试: 执行升级
     */
    function test_ExecuteUpgrade() public {
        address newImpl = address(tokenV2Implementation);
        token.scheduleUpgrade(newImpl);

        // 快进 7 天
        vm.warp(block.timestamp + 7 days + 1);

        token.executeUpgrade();

        // 验证升级成功
        RealEstateTokenV2 upgradedToken = RealEstateTokenV2(address(token));
        upgradedToken.setNewFeature(42);
        assertEq(upgradedToken.newFeature(), 42);

        // 验证状态已更新
        (, bool executed,,,) = token.pendingUpgrade();
        assertTrue(executed);
    }

    /**
     * @dev 测试: 时间锁未到期不能执行升级
     */
    function test_RevertWhen_ExecuteUpgradeBeforeTimelock() public {
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 快进 6 天 (不够 7 天)
        vm.warp(block.timestamp + 6 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                RealEstateToken.UpgradeTimelockNotExpired.selector,
                block.timestamp,
                block.timestamp + 1 days
            )
        );
        token.executeUpgrade();
    }

    /**
     * @dev 测试: 升级过期后不能执行
     */
    function test_RevertWhen_ExecuteUpgradeAfterExpiry() public {
        token.scheduleUpgrade(address(tokenV2Implementation));

        // 快进 15 天 (超过 7 天时间锁 + 7 天有效期)
        vm.warp(block.timestamp + 15 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                RealEstateToken.UpgradeExpired.selector,
                block.timestamp,
                block.timestamp - 1 days
            )
        );
        token.executeUpgrade();
    }

    /**
     * @dev 测试: 没有安排升级时不能执行
     */
    function test_RevertWhen_ExecuteUpgradeWithoutScheduling() public {
        vm.expectRevert(RealEstateToken.UpgradeNotScheduled.selector);
        token.executeUpgrade();
    }

    /**
     * @dev 测试: 取消升级
     */
    function test_CancelUpgrade() public {
        address newImpl = address(tokenV2Implementation);
        token.scheduleUpgrade(newImpl);

        token.cancelUpgrade();

        (, , bool cancelled,,) = token.pendingUpgrade();
        assertTrue(cancelled);
    }

    /**
     * @dev 测试: 取消后不能执行升级
     */
    function test_RevertWhen_ExecuteCancelledUpgrade() public {
        token.scheduleUpgrade(address(tokenV2Implementation));
        token.cancelUpgrade();

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(RealEstateToken.UpgradeAlreadyCancelled.selector);
        token.executeUpgrade();
    }

    /**
     * @dev 测试: 执行后不能再次执行升级
     */
    function test_RevertWhen_ExecuteUpgradeTwice() public {
        token.scheduleUpgrade(address(tokenV2Implementation));

        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        vm.expectRevert(RealEstateToken.UpgradeAlreadyExecuted.selector);
        RealEstateToken(address(token)).executeUpgrade();
    }

    /**
     * @dev 测试: 直接调用 UUPS 升级入口会被拒绝 (必须走 executeUpgrade)
     */
    function test_RevertWhen_DirectUpgradeCallBypassesFlow() public {
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(RealEstateToken.UpgradeMustUseExecuteFlow.selector);
        token.upgradeToAndCall(address(tokenV2Implementation), new bytes(0));
    }

    /**
     * @dev 测试: 只有 owner 可以安排升级
     */
    function test_RevertWhen_NonOwnerSchedulesUpgrade() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.scheduleUpgrade(address(tokenV2Implementation));
    }

    /**
     * @dev 测试: 只有 owner 可以执行升级
     */
    function test_RevertWhen_NonOwnerExecutesUpgrade() public {
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.executeUpgrade();
    }

    /**
     * @dev 测试: 只有 owner 可以取消升级
     */
    function test_RevertWhen_NonOwnerCancelsUpgrade() public {
        token.scheduleUpgrade(address(tokenV2Implementation));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.cancelUpgrade();
    }

    /**
     * @dev 测试: 取消后可以重新安排升级 (需要等待冷却期)
     */
    function test_RescheduleAfterCancel() public {
        address newImpl = address(tokenV2Implementation);
        token.scheduleUpgrade(newImpl);
        token.cancelUpgrade();

        // 快进 2 天冷却期
        vm.warp(block.timestamp + 2 days + 1);

        // 现在应该可以重新安排
        token.scheduleUpgrade(newImpl);

        (address impl, bool executed, bool cancelled, uint256 scheduledTime,) = token.pendingUpgrade();
        assertEq(impl, newImpl);
        assertEq(scheduledTime, block.timestamp + 7 days);
        assertFalse(executed);
        assertFalse(cancelled);
    }

    /**
     * @dev 测试: 取消后立即重新安排应该失败
     */
    function test_RevertWhen_RescheduleBeforeCooldown() public {
        address newImpl = address(tokenV2Implementation);
        token.scheduleUpgrade(newImpl);
        token.cancelUpgrade();

        // 立即尝试重新安排应该失败
        vm.expectRevert(
            abi.encodeWithSelector(
                RealEstateToken.CancelCooldownNotExpired.selector,
                block.timestamp,
                block.timestamp + token.CANCEL_COOLDOWN()
            )
        );
        token.scheduleUpgrade(newImpl);
    }

    /**
     * @dev 测试: 执行后可以安排新的升级
     */
    function test_ScheduleNewUpgradeAfterExecution() public {
        token.scheduleUpgrade(address(tokenV2Implementation));
        vm.warp(block.timestamp + 7 days + 1);
        token.executeUpgrade();

        // 部署新的 V3 实现
        RealEstateTokenV2 tokenV3Implementation = new RealEstateTokenV2();

        // 应该可以安排新的升级
        RealEstateToken(address(token)).scheduleUpgrade(address(tokenV3Implementation));

        (address impl,,,,) = RealEstateToken(address(token)).pendingUpgrade();
        assertEq(impl, address(tokenV3Implementation));
    }
}
