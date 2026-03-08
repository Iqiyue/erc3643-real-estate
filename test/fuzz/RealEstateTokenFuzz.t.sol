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
import "../../src/compliance/InvestorLimitsModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title RealEstateTokenFuzzTest
 * @dev Fuzzing 测试用于发现边界情况和潜在漏洞
 */
contract RealEstateTokenFuzzTest is Test {
    RealEstateToken public token;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    InvestorLimitsModule public investorLimitsModule;
    ClaimIssuer public claimIssuer;

    address public owner;
    address[] public investors;
    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;

    function setUp() public {
        owner = address(this);
        issuerOwner = vm.addr(issuerPrivateKey);

        // 部署身份系统
        vm.prank(issuerOwner);
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

        // 部署合规模块
        investorLimitsModule = new InvestorLimitsModule(
            1000,      // 最多1000个投资者
            5000,      // 单人最多持有50%
            1 ether    // 最小投资1代币
        );

        compliance = new ModularCompliance();

        // HIGH-1 修复: 使用调度和执行模式
        compliance.scheduleAddModule(address(investorLimitsModule));
        vm.warp(block.timestamp + 2 days + 1);
        compliance.addModule(address(investorLimitsModule));

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

        // 预注册一些投资者
        for (uint256 i = 0; i < 10; i++) {
            address investor = makeAddr(string(abi.encodePacked("investor", i)));
            investors.push(investor);
            _registerInvestor(investor);
        }
    }

    /**
     * @dev Fuzz 测试: 铸造随机数量的代币
     */
    function testFuzz_Mint(uint256 amount) public {
        // 限制范围避免溢出
        amount = bound(amount, 1 ether, 1000000 ether);

        address investor = investors[0];
        uint256 balanceBefore = token.balanceOf(investor);

        token.mint(investor, amount);

        assertEq(token.balanceOf(investor), balanceBefore + amount);
        assertEq(token.totalSupply(), balanceBefore + amount);
    }

    /**
     * @dev Fuzz 测试: 随机转账金额
     */
    function testFuzz_Transfer(uint256 mintAmount, uint256 transferAmount) public {
        mintAmount = bound(mintAmount, 10 ether, 1000000 ether);
        transferAmount = bound(transferAmount, 1 ether, mintAmount);

        address investor1 = investors[0];
        address investor2 = investors[1];

        token.mint(investor1, mintAmount);

        // 确保转账后不会违反最大持有比例限制 (50%)
        uint256 totalSupply = token.totalSupply();
        uint256 maxAllowed = (totalSupply * 5000) / 10000; // 50%

        if (transferAmount > maxAllowed) {
            transferAmount = maxAllowed;
        }

        vm.prank(investor1);
        assertTrue(token.transfer(investor2, transferAmount));

        assertEq(token.balanceOf(investor1), mintAmount - transferAmount);
        assertEq(token.balanceOf(investor2), transferAmount);
    }

    /**
     * @dev Fuzz 测试: 多次随机转账
     */
    function testFuzz_MultipleTransfers(uint256[5] memory amounts) public {
        // 铸造初始代币
        token.mint(investors[0], 1000000 ether);

        uint256 totalTransferred = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1 ether, 10000 ether);

            if (totalTransferred + amounts[i] > 1000000 ether) {
                break;
            }

            vm.prank(investors[0]);
            assertTrue(token.transfer(investors[i + 1], amounts[i]));

            totalTransferred += amounts[i];
        }

        assertEq(token.balanceOf(investors[0]), 1000000 ether - totalTransferred);
    }

    /**
     * @dev Fuzz 测试: 随机投资者数量
     */
    function testFuzz_InvestorCount(uint8 investorCount) public {
        investorCount = uint8(bound(investorCount, 1, 50));

        uint256 initialCount = token.investorCount();

        for (uint256 i = 0; i < investorCount; i++) {
            address investor = makeAddr(string(abi.encodePacked("fuzz_investor", i)));
            _registerInvestor(investor);
            token.mint(investor, 100 ether);
        }

        // 投资者数量应该等于初始数量 + 新增的
        assertEq(token.investorCount(), initialCount + investorCount);
    }

    /**
     * @dev Fuzz 测试: 随机销毁金额
     */
    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 100 ether, 1000000 ether);
        burnAmount = bound(burnAmount, 1 ether, mintAmount);

        address investor = investors[0];

        token.mint(investor, mintAmount);
        uint256 balanceAfterMint = token.balanceOf(investor);

        token.burn(investor, burnAmount);

        assertEq(token.balanceOf(investor), balanceAfterMint - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    /**
     * @dev Fuzz 测试: 不应该能转账超过余额
     */
    function testFuzz_CannotTransferMoreThanBalance(uint256 balance, uint256 transferAmount) public {
        balance = bound(balance, 1 ether, 1000000 ether);
        transferAmount = bound(transferAmount, balance + 1, type(uint256).max / 2);

        address investor1 = investors[0];
        address investor2 = investors[1];

        token.mint(investor1, balance);

        vm.prank(investor1);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, transferAmount);
    }

    /**
     * @dev Fuzz 测试: 最小投资金额限制
     */
    function testFuzz_MinimumInvestmentAmount(uint256 amount) public {
        // 测试小于最小投资额的情况
        if (amount < 1 ether) {
            vm.expectRevert();
            token.mint(investors[0], amount);
        } else {
            amount = bound(amount, 1 ether, 1000000 ether);
            token.mint(investors[0], amount);
            assertEq(token.balanceOf(investors[0]), amount);
        }
    }

    /**
     * @dev Fuzz 测试: 地址冻结后不能转账
     */
    function testFuzz_FrozenAddressCannotTransfer(uint256 amount) public {
        amount = bound(amount, 10 ether, 1000000 ether);

        address investor1 = investors[0];
        address investor2 = investors[1];

        token.mint(investor1, amount);
        token.freezeAddress(investor1);

        vm.prank(investor1);
        vm.expectRevert("Address frozen");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, amount / 2);
    }

    /**
     * @dev Fuzz 测试: 暂停后不能转账
     */
    function testFuzz_PausedTokenCannotTransfer(uint256 amount) public {
        amount = bound(amount, 10 ether, 1000000 ether);

        address investor1 = investors[0];
        address investor2 = investors[1];

        token.mint(investor1, amount);
        token.pause();

        vm.prank(investor1);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(investor2, amount / 2);
    }

    /**
     * @dev Fuzz 测试: 随机持币量百分比检查
     */
    function testFuzz_MaxHoldingPercentage(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 100 ether, 500000 ether);
        amount2 = bound(amount2, 100 ether, 500000 ether);

        address investor1 = investors[0];
        address investor2 = investors[1];

        token.mint(investor1, amount1);

        // 如果 amount2 会导致 investor2 持有超过50%,应该失败
        uint256 totalSupply = token.totalSupply() + amount2;
        if ((amount2 * 10000) / totalSupply > 5000) {
            vm.expectRevert();
        }

        token.mint(investor2, amount2);
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
        identity.addTrustedIssuer(address(claimIssuer));

        vm.prank(investor);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), 840);
    }
}
