// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/identity/Identity.sol";
import "../../src/identity/ClaimIssuer.sol";
import "../../src/identity/IdentityRegistryStorage.sol";
import "../../src/identity/IdentityRegistry.sol";
import "../../src/compliance/ModularCompliance.sol";
import "../../src/compliance/InvestorLimitsModule.sol";
import "../../src/compliance/TransferRestrictModule.sol";
import "../../src/token/RealEstateToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title SimpleIntegrationTest
 * @dev 简化的集成测试 - 测试核心流程
 */
contract SimpleIntegrationTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;
    InvestorLimitsModule public investorLimitsModule;
    TransferRestrictModule public transferRestrictModule;

    address public owner;
    address public agent;
    address public investor1;
    address public investor2;
    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;

    function setUp() public {
        owner = address(this);
        agent = makeAddr("agent");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
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

        // 部署合规系统
        compliance = new ModularCompliance();
        // maxInvestors=100, maxHoldingPercentage=10000 (100%), minInvestmentAmount=1 ether
        investorLimitsModule = new InvestorLimitsModule(100, 10000, 1 ether);
        transferRestrictModule = new TransferRestrictModule(30 days);

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
        token.addAgent(agent);

        // 添加合规模块
        compliance.scheduleAddModule(address(investorLimitsModule));
        vm.warp(block.timestamp + 2 days + 1);
        compliance.addModule(address(investorLimitsModule));

        compliance.scheduleAddModule(address(transferRestrictModule));
        vm.warp(block.timestamp + 2 days + 1);
        compliance.addModule(address(transferRestrictModule));
    }

    /**
     * @dev 测试完整的代币化流程
     */
    function testBasicTokenizationFlow() public {
        // 1. KYC 验证
        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        assertTrue(identityRegistry.isVerified(investor1));
        assertTrue(identityRegistry.isVerified(investor2));

        // 2. 铸造代币
        vm.startPrank(agent);
        token.mint(investor1, 1000 ether);
        vm.warp(block.timestamp + 2 minutes);
        token.mint(investor2, 500 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(investor1), 1000 ether);
        assertEq(token.balanceOf(investor2), 500 ether);
        assertEq(token.totalSupply(), 1500 ether);

        // 3. 测试锁定期
        vm.prank(investor1);
        vm.expectRevert("Transfer not compliant");
        token.transfer(investor2, 100 ether);

        // 4. 跳过锁定期后转账
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(investor1);
        token.transfer(investor2, 100 ether);

        assertEq(token.balanceOf(investor1), 900 ether);
        assertEq(token.balanceOf(investor2), 600 ether);
    }

    /**
     * @dev 测试合规限制
     */
    function testComplianceRestrictions() public {
        _registerInvestor(investor1, 840);
        _registerInvestor(investor2, 840);

        // 测试最小投资金额限制 (mint 时)
        vm.prank(agent);
        vm.expectRevert("Mint not compliant");
        token.mint(investor1, 0.5 ether); // 小于 1 ether 最小投资额

        // 成功 mint
        vm.startPrank(agent);
        token.mint(investor1, 1000 ether);
        vm.warp(block.timestamp + 2 minutes);
        token.mint(investor2, 500 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(investor1), 1000 ether);
        assertEq(token.balanceOf(investor2), 500 ether);

        // 测试锁定期后的转账
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(investor1);
        token.transfer(investor2, 100 ether);
        assertEq(token.balanceOf(investor2), 600 ether);
    }

    /**
     * @dev 辅助函数: 注册投资者
     */
    function _registerInvestor(address investor, uint16 country) internal {
        vm.prank(investor);
        Identity identity = new Identity(investor);

        vm.prank(investor);
        identity.addTrustedIssuer(address(claimIssuer));

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(investor);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), country);
    }
}
