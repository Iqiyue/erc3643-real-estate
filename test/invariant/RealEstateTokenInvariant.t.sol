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
 * @title TokenHandler
 * @dev 处理器合约,定义可以执行的操作
 */
contract TokenHandler is Test {
    RealEstateToken public token;
    IdentityRegistry public identityRegistry;
    address[] public actors;

    constructor(RealEstateToken _token, IdentityRegistry _identityRegistry, address[] memory _actors) {
        token = _token;
        identityRegistry = _identityRegistry;
        actors = _actors;
    }

    function mint(uint256 actorSeed, uint256 amount) public {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, 1 ether, 100000 ether);

        try token.mint(actor, amount) {} catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[bound(fromSeed, 0, actors.length - 1)];
        address to = actors[bound(toSeed, 0, actors.length - 1)];

        if (from == to) return;

        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(from);
        try token.transfer(to, amount) {} catch {}
    }

    function burn(uint256 actorSeed, uint256 amount) public {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = token.balanceOf(actor);

        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        try token.burn(actor, amount) {} catch {}
    }
}

/**
 * @title RealEstateTokenInvariantTest
 * @dev Invariant 测试用于验证系统不变量
 */
contract RealEstateTokenInvariantTest is Test {
    RealEstateToken public token;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    TokenHandler public handler;

    address[] public actors;
    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;
    ClaimIssuer public claimIssuer;

    function setUp() public {
        // 部署身份系统
        issuerOwner = vm.addr(issuerPrivateKey);
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
        token.addAgent(address(this));

        // 创建测试角色
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            _registerInvestor(actor);
        }

        // 创建处理器
        handler = new TokenHandler(token, identityRegistry, actors);
        token.addAgent(address(handler));

        // 设置目标合约
        targetContract(address(handler));
    }

    /**
     * @dev 不变量1: 总供应量应该等于所有余额之和
     */
    function invariant_TotalSupplyEqualsBalances() public view {
        uint256 totalBalance = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            totalBalance += token.balanceOf(actors[i]);
        }

        assertEq(token.totalSupply(), totalBalance, "Total supply != sum of balances");
    }

    /**
     * @dev 不变量2: 投资者计数应该等于非零余额的地址数量
     */
    function invariant_InvestorCountMatchesNonZeroBalances() public view {
        uint256 nonZeroCount = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                nonZeroCount++;
            }
        }

        assertEq(token.investorCount(), nonZeroCount, "Investor count mismatch");
    }

    /**
     * @dev 不变量3: 所有投资者的余额都应该 >= 0
     */
    function invariant_BalancesNonNegative() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertTrue(token.balanceOf(actors[i]) >= 0, "Negative balance detected");
        }
    }

    /**
     * @dev 不变量4: 如果地址有余额,应该被标记为投资者
     */
    function invariant_NonZeroBalanceIsInvestor() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                assertTrue(token.isInvestor(actors[i]), "Non-zero balance but not marked as investor");
            }
        }
    }

    /**
     * @dev 不变量5: 如果地址余额为0,不应该被标记为投资者
     */
    function invariant_ZeroBalanceNotInvestor() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) == 0) {
                assertFalse(token.isInvestor(actors[i]), "Zero balance but marked as investor");
            }
        }
    }

    /**
     * @dev 不变量6: 总供应量不应该溢出
     */
    function invariant_TotalSupplyNoOverflow() public view {
        assertTrue(token.totalSupply() <= type(uint256).max, "Total supply overflow");
    }

    /**
     * @dev 不变量7: 投资者列表中的所有地址都应该有非零余额
     */
    function invariant_InvestorListHasNonZeroBalances() public view {
        address[] memory investorList = token.getInvestors();

        for (uint256 i = 0; i < investorList.length; i++) {
            assertTrue(token.balanceOf(investorList[i]) > 0, "Investor in list has zero balance");
        }
    }

    /**
     * @dev 不变量8: 投资者列表长度应该等于投资者计数
     */
    function invariant_InvestorListLengthMatchesCount() public view {
        address[] memory investorList = token.getInvestors();
        assertEq(investorList.length, token.investorCount(), "Investor list length mismatch");
    }

    /**
     * @dev 不变量9: 代币名称和符号不应该改变
     */
    function invariant_TokenMetadataUnchanged() public view {
        assertEq(token.name(), "Real Estate Token", "Token name changed");
        assertEq(token.symbol(), "RET", "Token symbol changed");
    }

    /**
     * @dev 不变量10: 所有余额之和不应该超过 uint256 最大值
     */
    function invariant_BalancesSumNoOverflow() public view {
        uint256 sum = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 balance = token.balanceOf(actors[i]);
            // 检查加法不会溢出
            assertTrue(sum + balance >= sum, "Balance sum overflow");
            sum += balance;
        }
    }

    // 辅助函数
    function _registerInvestor(address investor) internal {
        Identity identity = new Identity(investor);
        ClaimIssuer issuer = ClaimIssuer(identityRegistry.trustedIssuersList(0));

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = issuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // HIGH-2 修复: 添加受信任的签发者
        vm.prank(investor);
        identity.authorizeClaimIssuer(address(issuer));

        vm.prank(investor);
        identity.addClaim(1, 1, address(issuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), 840);
    }
}
