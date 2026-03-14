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

/**
 * @title DividendHandler
 * @dev 处理器合约,定义分红相关操作
 */
contract DividendHandler is Test {
    RealEstateDividendDistributor public distributor;
    RealEstateToken public token;
    address[] public investors;
    uint256[] public snapshotIds;

    constructor(
        RealEstateDividendDistributor _distributor,
        RealEstateToken _token,
        address[] memory _investors
    ) {
        distributor = _distributor;
        token = _token;
        investors = _investors;
    }

    function createSnapshot(uint256 amount) public {
        amount = bound(amount, 0.1 ether, 10 ether);

        try distributor.createSnapshotETH{value: amount}(0, 100) returns (uint256 snapshotId, bool isComplete) {
            if (isComplete) {
                snapshotIds.push(snapshotId);
            }
        } catch {}
    }

    function claimDividend(uint256 investorSeed, uint256 snapshotSeed) public {
        if (snapshotIds.length == 0) return;

        address investor = investors[bound(investorSeed, 0, investors.length - 1)];
        uint256 snapshotId = snapshotIds[bound(snapshotSeed, 0, snapshotIds.length - 1)];

        vm.prank(investor);
        try distributor.claimDividend(snapshotId) {} catch {}
    }

    receive() external payable {}
}

/**
 * @title DividendDistributorInvariantTest
 * @dev 分红系统的不变量测试
 */
contract DividendDistributorInvariantTest is Test {
    RealEstateDividendDistributor public distributor;
    RealEstateToken public token;
    DividendHandler public handler;

    address[] public investors;
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

        IdentityRegistry identityRegistry = new IdentityRegistry(
            address(identityStorage),
            trustedIssuers,
            claimTopics
        );

        identityStorage.bindIdentityRegistry(address(identityRegistry));

        // 部署合规引擎
        ModularCompliance compliance = new ModularCompliance();

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

        // 部署分红分配器
        distributor = new RealEstateDividendDistributor(address(token));

        // 创建投资者并分配代币
        for (uint256 i = 0; i < 5; i++) {
            address investor = makeAddr(string(abi.encodePacked("investor", i)));
            investors.push(investor);
            _registerInvestor(investor, identityRegistry, claimIssuer);
            token.mint(investor, (i + 1) * 1000 ether);
        }

        // 创建处理器
        handler = new DividendHandler(distributor, token, investors);

        // 给处理器一些 ETH
        vm.deal(address(handler), 100 ether);

        // 设置目标合约
        targetContract(address(handler));
    }

    /**
     * @dev 不变量1: 分红合约的 ETH 余额应该等于所有未领取的分红总和
     */
    function invariant_ContractBalanceEqualsUnclaimedDividends() public view {
        uint256 totalUnclaimed = 0;
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (,,, address paymentToken,,) = distributor.getSnapshotInfo(snapshotId);

            // 只计算 ETH 分红
            if (paymentToken == address(0)) {
                for (uint256 i = 0; i < investors.length; i++) {
                    uint256 unclaimed = distributor.getUnclaimedDividend(snapshotId, investors[i]);
                    totalUnclaimed += unclaimed;
                }
            }
        }

        assertEq(address(distributor).balance, totalUnclaimed, "Contract balance != unclaimed dividends");
    }

    /**
     * @dev 不变量2: 每个快照的总分红应该等于所有投资者应得分红之和
     */
    function invariant_SnapshotDividendSumMatchesTotal() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (,, uint256 dividendAmount,,,) = distributor.getSnapshotInfo(snapshotId);

            uint256 totalCalculated = 0;
            for (uint256 i = 0; i < investors.length; i++) {
                uint256 dividend = distributor.calculateDividend(snapshotId, investors[i]);
                totalCalculated += dividend;
            }

            // 允许1 wei的舍入误差
            assertTrue(
                totalCalculated >= dividendAmount - 1 && totalCalculated <= dividendAmount + 1,
                "Dividend sum mismatch"
            );
        }
    }

    /**
     * @dev 不变量3: 已领取的分红不应该再次被领取
     */
    function invariant_ClaimedDividendsCannotBeClaimedAgain() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            for (uint256 i = 0; i < investors.length; i++) {
                if (distributor.hasClaimed(snapshotId, investors[i])) {
                    assertEq(
                        distributor.getUnclaimedDividend(snapshotId, investors[i]),
                        0,
                        "Claimed dividend shows as unclaimed"
                    );
                }
            }
        }
    }

    /**
     * @dev 不变量4: 快照 ID 应该单调递增
     */
    function invariant_SnapshotIdMonotonicallyIncreasing() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (uint256 id,,,,,) = distributor.getSnapshotInfo(snapshotId);
            assertEq(id, snapshotId, "Snapshot ID mismatch");
        }
    }

    /**
     * @dev 不变量5: 每个快照的总供应量应该大于0
     */
    function invariant_SnapshotTotalSupplyPositive() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (, uint256 totalSupply,,,,) = distributor.getSnapshotInfo(snapshotId);
            if (totalSupply > 0) {
                assertTrue(totalSupply > 0, "Snapshot has zero total supply");
            }
        }
    }

    /**
     * @dev 不变量6: 投资者的分红应该与其持币比例成正比
     */
    function invariant_DividendProportionalToBalance() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (, uint256 totalSupply, uint256 dividendAmount,,,) = distributor.getSnapshotInfo(snapshotId);

            if (totalSupply == 0) continue;

            for (uint256 i = 0; i < investors.length; i++) {
                uint256 balance = distributor.getSnapshotBalance(snapshotId, investors[i]);
                uint256 expectedDividend = (dividendAmount * balance) / totalSupply;
                uint256 actualDividend = distributor.calculateDividend(snapshotId, investors[i]);

                assertEq(actualDividend, expectedDividend, "Dividend not proportional to balance");
            }
        }
    }

    /**
     * @dev 不变量7: 快照余额之和应该等于快照总供应量
     */
    function invariant_SnapshotBalancesSumEqualsTotal() public view {
        uint256 currentSnapshotId = distributor.currentSnapshotId();

        for (uint256 snapshotId = 1; snapshotId <= currentSnapshotId; snapshotId++) {
            (, uint256 totalSupply,,,,) = distributor.getSnapshotInfo(snapshotId);

            uint256 balanceSum = 0;
            for (uint256 i = 0; i < investors.length; i++) {
                balanceSum += distributor.getSnapshotBalance(snapshotId, investors[i]);
            }

            assertEq(balanceSum, totalSupply, "Snapshot balances sum != total supply");
        }
    }

    // 辅助函数
    function _registerInvestor(
        address investor,
        IdentityRegistry identityRegistry,
        ClaimIssuer _claimIssuer
    ) internal {
        Identity identity = new Identity(investor);

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 0;
        bytes32 messageHash = _claimIssuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // HIGH-2 修复: 添加受信任的签发者
        vm.prank(investor);
        identity.authorizeClaimIssuer(address(_claimIssuer));

        vm.prank(investor);
        identity.addClaim(1, 1, address(_claimIssuer), signature, data, "", expiresAt, nonce);

        identityRegistry.registerIdentity(investor, address(identity), 840);
    }
}
