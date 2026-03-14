// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/CountryRestrictModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/InvestorLimitsModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/TransferRestrictModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/ModularCompliance.sol";
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
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ComplianceModulesTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;

    CountryRestrictModule public countryModule;
    InvestorLimitsModule public investorLimitsModule;
    TransferRestrictModule public transferRestrictModule;

    address public owner;
    address public investor1;
    address public investor2;
    address public investor3;
    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;

    function setUp() public {
        owner = address(this);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
        investor3 = makeAddr("investor3");
        issuerOwner = vm.addr(issuerPrivateKey);

        // 部署身份系统
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

        // 部署合规模块
        countryModule = new CountryRestrictModule(true); // 白名单模式
        countryModule.addCountryToWhitelist(840); // USA

        investorLimitsModule = new InvestorLimitsModule(
            10,        // 最多10个投资者
            3000,      // 单人最多持有30%
            100 ether  // 最小投资100代币
        );
         transferRestrictModule = new TransferRestrictModule(
            30 days  // 30天锁定期
        );

        // 部署合规引擎
        compliance = new ModularCompliance();

        // HIGH-1 修复: 使用调度和执行模式添加模块
        compliance.scheduleAddModule(address(countryModule));
        compliance.scheduleAddModule(address(investorLimitsModule));
        compliance.scheduleAddModule(address(transferRestrictModule));

        // 快进时间以通过时间锁
        vm.warp(block.timestamp + 2 days + 1);

        compliance.addModule(address(countryModule));
        compliance.addModule(address(investorLimitsModule));
        compliance.addModule(address(transferRestrictModule));

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
    }

    function testCountryRestriction() public {
        // 注册美国投资者 (允许)
        _registerInvestor(investor1, 840); // USA
        token.mint(investor1, 1000 ether);
        assertEq(token.balanceOf(investor1), 1000 ether);

        // 尝试注册中国投资者 (不允许)
        _registerInvestor(investor2, 156); // China
        vm.expectRevert();
        token.mint(investor2, 1000 ether);
    }

    function testInvestorLimits() public {
        _registerInvestor(investor1, 840);

        // 测试最小投资金额
        vm.expectRevert();
        token.mint(investor1, 50 ether); // 低于最小投资额

        // 测试最大持币量
        token.mint(investor1, 1000 ether);
        vm.expectRevert();
        token.mint(investor1, 2000 ether); // 超过30%限制
    }

    function testLockupPeriod() public {
        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        token.mint(investor1, 1000 ether);

        // 锁定期内不能转账
        vm.prank(investor1);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, 100 ether);

        // 30天后可以转账
        vm.warp(block.timestamp + 31 days);
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100 ether));

        assertEq(token.balanceOf(investor2), 100 ether);
    }

    function testLockupWhitelist() public {
        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        token.mint(investor1, 1000 ether);

        // 将 investor1 添加到白名单
        transferRestrictModule.addToWhitelist(investor1);

        // 白名单用户可以在锁定期内转账
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100 ether));

        assertEq(token.balanceOf(investor2), 100 ether);
    }

    function testMultipleComplianceModules() public {
        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        // 铸造代币
        token.mint(investor1, 1000 ether);

        // 所有合规检查都必须通过
        // 1. 国家检查 ✓
        // 2. 投资者限制 ✓
        // 3. 锁定期检查 ✗

        vm.prank(investor1);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, 100 ether);

        // 等待锁定期结束
        vm.warp(block.timestamp + 31 days);

        // 现在所有检查都通过
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100 ether));

        assertEq(token.balanceOf(investor2), 100 ether);
    }

    function testRemoveComplianceModule() public {
        // HIGH-1 修复: 调度移除模块
        compliance.scheduleRemoveModule(address(transferRestrictModule));
        vm.warp(block.timestamp + 2 days + 1);

        // 移除锁定期模块
        compliance.removeModule(address(transferRestrictModule));

        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        token.mint(investor1, 1000 ether);

        // 没有锁定期限制,可以立即转账
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100 ether));

        assertEq(token.balanceOf(investor2), 100 ether);
    }

    function testModeSwitchClearsStaleRules() public {
        _registerInvestor(investor1, 840); // USA
        _registerInvestor(investor2, 156); // China
        _registerInvestor(investor3, 840); // USA

        token.mint(investor1, 1000 ether);

        // 切到黑名单模式时,旧白名单应被清空,默认允许
        countryModule.setMode(false);
        token.mint(investor2, 300 ether);
        assertEq(token.balanceOf(investor2), 300 ether);

        // 配置黑名单后应生效
        countryModule.addCountryToBlacklist(156);
        vm.expectRevert();
        token.mint(investor2, 1 ether);

        // 切回白名单模式时,旧黑名单应被清空,默认拒绝直到重新配置白名单
        countryModule.setMode(true);
        vm.expectRevert();
        token.mint(investor3, 100 ether);
    }

    // 辅助函数
    function _registerInvestor(address investor, uint16 country) internal {
        Identity identity = new Identity(investor);

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // HIGH-2 修复: 添加受信任的签发者
        vm.prank(investor);
        identity.addTrustedIssuer(address(claimIssuer));

        vm.prank(investor);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), country);
    }
}
