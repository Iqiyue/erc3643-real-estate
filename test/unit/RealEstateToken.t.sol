// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/Identity.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityFactory.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/ClaimIssuer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityRegistryStorage.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/token/RealEstateToken.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RealEstateTokenTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityFactory public identityFactory;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;

    address public owner;
    address public investor1;
    address public investor2;
    address public investor3;
    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;
    address public guardian;
    address public rando;

    function setUp() public {
        owner = address(this);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
        investor3 = makeAddr("investor3");
        issuerOwner = vm.addr(issuerPrivateKey);
        guardian = makeAddr("guardian");
        rando = makeAddr("rando");

        // 部署合约
        vm.prank(issuerOwner);
        claimIssuer = new ClaimIssuer();
        Identity identityImplementation = new Identity(address(0));
        identityFactory = new IdentityFactory(address(identityImplementation));
        identityStorage = new IdentityRegistryStorage();

        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1; // KYC

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
    }

    function testInitialization() public view {
        assertEq(token.name(), "Real Estate Token");
        assertEq(token.symbol(), "RET");
        assertEq(address(token.identityRegistry()), address(identityRegistry));
        assertEq(address(token.compliance()), address(compliance));
    }

    function testRegisterIdentity() public {
        // 创建投资者身份
        Identity identity1 = Identity(identityFactory.createIdentity(investor1));

        // 签发 KYC 声明
        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity1), 1, data, expiresAt, nonce);

        // 模拟签名(在实际场景中,这应该由 ClaimIssuer 的私钥签名)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash); // 使用测试私钥
        bytes memory signature = abi.encodePacked(r, s, v);

        // HIGH-2 修复: 添加受信任的签发者
        vm.prank(investor1);
        identity1.authorizeClaimIssuer(address(claimIssuer));

        // 添加声明到身份
        vm.prank(investor1);
        identity1.addClaim(
            1, // topic: KYC
            1, // scheme: ECDSA
            address(claimIssuer),
            signature,
            data,
            "",
            expiresAt,
            nonce
        );

        // 注册身份
        identityRegistry.registerIdentity(investor1, address(identity1), 840); // 840 = USA

        // 验证注册成功
        assertTrue(identityRegistry.isVerified(investor1));
        assertEq(identityRegistry.identity(investor1), address(identity1));
        assertEq(identityRegistry.investorCountry(investor1), 840);
    }

    function testMintTokens() public {
        // 先注册投资者
        _registerInvestor(investor1);

        // 添加代理人权限
        token.addAgent(owner);

        // 铸造代币
        token.mint(investor1, 1000 ether);

        // 验证余额
        assertEq(token.balanceOf(investor1), 1000 ether);
        assertEq(token.investorCount(), 1);
        assertTrue(token.isInvestor(investor1));
    }

    function testTransferBetweenVerifiedInvestors() public {
        // 注册两个投资者
        _registerInvestor(investor1);
        _registerInvestor(investor2);

        // 铸造代币给 investor1
        token.addAgent(owner);
        token.mint(investor1, 1000 ether);

        // investor1 转账给 investor2
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 500 ether));

        // 验证余额
        assertEq(token.balanceOf(investor1), 500 ether);
        assertEq(token.balanceOf(investor2), 500 ether);
        assertEq(token.investorCount(), 2);
    }

    function test_RevertWhen_TransferToUnverifiedAddress() public {
        // 注册 investor1
        _registerInvestor(investor1);

        // 铸造代币
        token.addAgent(owner);
        token.mint(investor1, 1000 ether);

        // 尝试转账给未验证的地址(应该失败)
        vm.prank(investor1);
        vm.expectRevert("Receiver not verified");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, 500 ether); // investor2 未验证
    }

    function testPauseAndUnpause() public {
        _registerInvestor(investor1);
        _registerInvestor(investor2);

        token.addAgent(owner);
        token.mint(investor1, 1000 ether);

        // 暂停代币
        token.pause();

        // 尝试转账(应该失败)
        vm.prank(investor1);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, 500 ether);

        // 恢复代币
        token.unpause();

        // 再次尝试转账(应该成功)
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 500 ether));

        assertEq(token.balanceOf(investor2), 500 ether);
    }

    function testAutoUnpauseCannotBypassOwnerPause() public {
        // Formal pause by owner must not be auto-unpaused by the public.
        token.pause();
        assertTrue(token.paused());

        vm.warp(block.timestamp + token.EMERGENCY_PAUSE_DURATION() + 1);
        vm.prank(rando);
        vm.expectRevert();
        token.autoUnpause();

        assertTrue(token.paused());
    }

    function testAutoUnpauseAfterGuardianEmergencyPause() public {
        token.setGuardian(guardian);

        // Guardian emergency pause has a cooldown guard; the first call requires time > cooldown since 0.
        vm.warp(block.timestamp + token.EMERGENCY_PAUSE_COOLDOWN() + 1);
        vm.prank(guardian);
        token.emergencyPause();
        assertTrue(token.paused());
        assertGt(token.emergencyPauseUntil(), 0);

        // Still active right before expiry.
        vm.warp(block.timestamp + token.EMERGENCY_PAUSE_DURATION());
        vm.prank(rando);
        vm.expectRevert();
        token.autoUnpause();

        // One second after expiry, anyone can auto-unpause.
        vm.warp(block.timestamp + 1);
        vm.prank(rando);
        token.autoUnpause();

        assertFalse(token.paused());
        assertEq(token.emergencyPauseUntil(), 0);
    }

    function testOwnerUnpauseClearsEmergencyDeadline() public {
        token.setGuardian(guardian);

        // Guardian emergency pause has a cooldown guard; the first call requires time > cooldown since 0.
        vm.warp(block.timestamp + token.EMERGENCY_PAUSE_COOLDOWN() + 1);
        vm.prank(guardian);
        token.emergencyPause();
        assertTrue(token.paused());
        assertGt(token.emergencyPauseUntil(), 0);

        // Owner unpauses early; should clear the emergency deadline.
        token.unpause();
        assertFalse(token.paused());
        assertEq(token.emergencyPauseUntil(), 0);

        // Later a formal pause should not be auto-unpaused by anyone.
        token.pause();
        vm.warp(block.timestamp + token.EMERGENCY_PAUSE_DURATION() + 1);
        vm.prank(rando);
        vm.expectRevert();
        token.autoUnpause();
        assertTrue(token.paused());
    }

    function testForcedTransferByAgent() public {
        _registerInvestor(investor1);
        _registerInvestor(investor2);
        token.addAgent(owner);
        token.mint(investor1, 1000 ether);

        token.forcedTransfer(investor1, investor2, 400 ether);

        assertEq(token.balanceOf(investor1), 600 ether);
        assertEq(token.balanceOf(investor2), 400 ether);
    }

    function testRecoveryAddress() public {
        _registerInvestor(investor1);
        _registerInvestor(investor2);
        token.addAgent(owner);
        token.mint(investor1, 750 ether);

        token.recoveryAddress(investor1, investor2);

        assertEq(token.balanceOf(investor1), 0);
        assertEq(token.balanceOf(investor2), 750 ether);
    }

    function testSetIdentityRegistryAndCompliance() public {
        IdentityRegistryStorage newStorage = new IdentityRegistryStorage();

        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;

        IdentityRegistry newRegistry = new IdentityRegistry(address(newStorage), trustedIssuers, claimTopics);
        newStorage.bindIdentityRegistry(address(newRegistry));

        ModularCompliance newCompliance = new ModularCompliance();
        newCompliance.bindToken(address(token));

        token.scheduleIdentityRegistryUpdate(address(newRegistry));
        token.scheduleComplianceUpdate(address(newCompliance));
        vm.warp(block.timestamp + token.SYSTEM_UPDATE_DELAY() + 1);

        token.setIdentityRegistry(address(newRegistry));
        token.setCompliance(address(newCompliance));

        assertEq(address(token.identityRegistry()), address(newRegistry));
        assertEq(address(token.compliance()), address(newCompliance));
    }

    function testRevertWhen_SetIdentityRegistryWithoutSchedule() public {
        IdentityRegistryStorage newStorage = new IdentityRegistryStorage();
        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;
        IdentityRegistry newRegistry = new IdentityRegistry(address(newStorage), trustedIssuers, claimTopics);
        newStorage.bindIdentityRegistry(address(newRegistry));

        vm.expectRevert(RealEstateToken.SystemUpdateNotScheduled.selector);
        token.setIdentityRegistry(address(newRegistry));
    }

    function testRevertWhen_ScheduleInvalidIdentityRegistry() public {
        IdentityRegistryStorage badStorage = new IdentityRegistryStorage();
        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;
        IdentityRegistry badRegistry = new IdentityRegistry(address(badStorage), trustedIssuers, claimTopics);
        // NOTE: intentionally not binding badStorage to badRegistry

        vm.expectRevert(abi.encodeWithSelector(RealEstateToken.InvalidIdentityRegistryConfig.selector, address(badRegistry)));
        token.scheduleIdentityRegistryUpdate(address(badRegistry));
    }

    function testBatchRegisterIdentityDelegatesToVerifiedFlow() public {
        address[] memory users = new address[](2);
        address[] memory identities = new address[](2);
        uint16[] memory countries = new uint16[](2);

        users[0] = investor1;
        users[1] = investor2;
        countries[0] = 840;
        countries[1] = 840;

        Identity identity1 = Identity(identityFactory.createIdentity(investor1));
        Identity identity2 = Identity(identityFactory.createIdentity(investor2));
        identities[0] = address(identity1);
        identities[1] = address(identity2);

        _addKycClaim(identity1, investor1);
        _addKycClaim(identity2, investor2);

        identityRegistry.batchRegisterIdentity(users, identities, countries);

        assertEq(identityRegistry.identity(investor1), address(identity1));
        assertEq(identityRegistry.identity(investor2), address(identity2));
        assertTrue(identityRegistry.isVerified(investor1));
        assertTrue(identityRegistry.isVerified(investor2));
    }

    function testRevertWhen_BatchRegisterIdentityContainsUnverifiedIdentity() public {
        address[] memory users = new address[](2);
        address[] memory identities = new address[](2);
        uint16[] memory countries = new uint16[](2);

        users[0] = investor1;
        users[1] = investor2;
        countries[0] = 840;
        countries[1] = 840;

        Identity identity1 = Identity(identityFactory.createIdentity(investor1));
        Identity identity2 = Identity(identityFactory.createIdentity(investor2));
        identities[0] = address(identity1);
        identities[1] = address(identity2);

        // 仅给第一个身份添加 KYC Claim,第二个身份保持未验证
        _addKycClaim(identity1, investor1);

        vm.expectRevert("Identity not verified");
        identityRegistry.batchRegisterIdentity(users, identities, countries);
    }

    function testRevertWhen_BatchForcedTransferToFrozenAddress() public {
        _registerInvestor(investor1);
        _registerInvestor(investor2);
        _registerInvestor(investor3);
        token.addAgent(owner);
        token.mint(investor1, 1000 ether);
        token.freezeAddress(investor3);

        address[] memory fromList = new address[](1);
        address[] memory toList = new address[](1);
        uint256[] memory amountList = new uint256[](1);
        fromList[0] = investor1;
        toList[0] = investor3;
        amountList[0] = 100 ether;

        vm.expectRevert(abi.encodeWithSelector(RealEstateToken.AddressFrozen.selector, investor3));
        token.batchForcedTransfer(fromList, toList, amountList);
    }

    // 辅助函数:注册投资者
    function _registerInvestor(address investor) internal {
        Identity identity = Identity(identityFactory.createIdentity(investor));
        _addKycClaim(identity, investor);

        identityRegistry.registerIdentity(investor, address(identity), 840);
    }

    function _addKycClaim(Identity identity, address investor) internal {
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
    }
}
