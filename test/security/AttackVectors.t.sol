// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/identity/Identity.sol";
import "../../src/identity/ClaimIssuer.sol";
import "../../src/identity/IdentityRegistryStorage.sol";
import "../../src/identity/IdentityRegistry.sol";
import "../../src/compliance/ModularCompliance.sol";
import "../../src/token/RealEstateToken.sol";
import "../../src/distribution/RealEstateDividendDistributor.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ReentrancyAttackTest
 * @dev 测试重入攻击防护
 */
contract ReentrancyAttackTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;
    RealEstateDividendDistributor public dividendDistributor;

    address public owner;
    address public agent;
    address public attacker;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        agent = makeAddr("agent");
        attacker = makeAddr("attacker");
        issuerOwner = vm.addr(issuerPrivateKey);

        // 部署合约
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
        token.addAgent(agent);

        dividendDistributor = new RealEstateDividendDistributor(address(token));
    }

    /**
     * @dev 测试分红领取的重入攻击防护
     */
    function testReentrancyAttackOnDividendClaim() public {
        // 部署恶意合约
        MaliciousReceiver malicious = new MaliciousReceiver(address(dividendDistributor));

        // 注册恶意合约为投资者
        _registerInvestor(address(malicious), 840);

        // 铸造代币给恶意合约
        vm.prank(agent);
        token.mint(address(malicious), 1000 ether);

        // 暂停代币以创建快照
        token.pause();

        // 创建分红快照
        vm.deal(address(dividendDistributor), 10 ether);
        (uint256 snapshotId, ) = dividendDistributor.createSnapshotETH{value: 10 ether}(0, 100);

        // 恢复代币
        token.unpause();

        // 设置恶意合约的攻击目标
        malicious.setSnapshotId(snapshotId);

        // 执行攻击 - 第一次调用会成功,但重入会被阻止
        malicious.attack();

        // 验证攻击计数器只增加了 1 次(重入被阻止)
        assertEq(malicious.attackCount(), 1);

        // 验证分红只能领取一次
        assertTrue(dividendDistributor.hasClaimed(snapshotId, address(malicious)));
    }

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

/**
 * @title MaliciousReceiver
 * @dev 恶意接收者合约,尝试重入攻击
 */
contract MaliciousReceiver {
    RealEstateDividendDistributor public distributor;
    uint256 public snapshotId;
    uint256 public attackCount;

    constructor(address _distributor) {
        distributor = RealEstateDividendDistributor(payable(_distributor));
    }

    function setSnapshotId(uint256 _snapshotId) external {
        snapshotId = _snapshotId;
    }

    function attack() external {
        distributor.claimDividend(snapshotId);
    }

    receive() external payable {
        attackCount++;
        // 尝试重入 (应该被 nonReentrant 阻止)
        if (attackCount < 3) {
            try distributor.claimDividend(snapshotId) {
                // 不应该成功
            } catch {
                // 预期会失败
            }
        }
    }
}

/**
 * @title AccessControlAttackTest
 * @dev 测试访问控制绕过攻击
 */
contract AccessControlAttackTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;

    address public owner;
    address public attacker;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
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
    }

    /**
     * @dev 测试非 agent 尝试铸造代币
     */
    function testUnauthorizedMint() public {
        address victim = makeAddr("victim");

        vm.prank(attacker);
        vm.expectRevert();
        token.mint(victim, 1000 ether);
    }

    /**
     * @dev 测试非 owner 尝试添加 agent
     */
    function testUnauthorizedAddAgent() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.addAgent(attacker);
    }

    /**
     * @dev 测试非 owner 尝试升级合约
     */
    function testUnauthorizedUpgrade() public {
        RealEstateToken newImplementation = new RealEstateToken();

        vm.prank(attacker);
        vm.expectRevert();
        token.scheduleUpgrade(address(newImplementation));
    }

    /**
     * @dev 测试非 owner 尝试添加合规模块
     */
    function testUnauthorizedAddComplianceModule() public {
        address fakeModule = makeAddr("fakeModule");

        vm.prank(attacker);
        vm.expectRevert();
        compliance.scheduleAddModule(fakeModule);
    }
}

/**
 * @title FrontRunningAttackTest
 * @dev 测试前端运行攻击防护
 */
contract FrontRunningAttackTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;

    address public owner;
    address public agent;
    address public investor1;
    address public attacker;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        agent = makeAddr("agent");
        investor1 = makeAddr("investor1");
        attacker = makeAddr("attacker");
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
        token.addAgent(agent);
    }

    /**
     * @dev 测试 mint 频率限制防止抢跑
     */
    function testMintFrequencyLimit() public {
        _registerInvestor(investor1, 840);

        // 第一次 mint
        vm.prank(agent);
        token.mint(investor1, 1000 ether);

        // 立即尝试第二次 mint (应该失败)
        vm.prank(agent);
        vm.expectRevert("Mint too frequent");
        token.mint(investor1, 500 ether);

        // 等待时间间隔后可以 mint
        vm.warp(block.timestamp + 1 minutes + 1);

        vm.prank(agent);
        token.mint(investor1, 500 ether);

        assertEq(token.balanceOf(investor1), 1500 ether);
    }

    /**
     * @dev 测试签名重放攻击防护
     */
    function testSignatureReplayAttack() public {
        vm.prank(investor1);
        Identity identity = new Identity(investor1);

        vm.prank(investor1);
        identity.addTrustedIssuer(address(claimIssuer));

        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        uint256 nonce = 1; // 使用 nonce

        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), 1, data, expiresAt, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 第一次添加 claim
        vm.prank(investor1);
        identity.addClaim(1, 1, address(claimIssuer), signature, data, "", expiresAt, nonce);

        // 标记 nonce 已使用
        claimIssuer.markNonceUsed(address(identity), nonce);

        // 尝试重放相同的签名 (应该失败)
        assertFalse(claimIssuer.isClaimValid(address(identity), 1, data, signature, expiresAt, nonce));
    }

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

/**
 * @title DoSAttackTest
 * @dev 测试 DoS 攻击防护
 */
contract DoSAttackTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    RealEstateToken public token;

    address public owner;
    address public agent;
    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;

    function setUp() public {
        owner = address(this);
        agent = makeAddr("agent");
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
        token.addAgent(agent);
    }

    /**
     * @dev 测试批量操作的大小限制
     */
    function testBatchOperationSizeLimit() public {
        // 创建超过限制的数组
        address[] memory recipients = new address[](101);
        uint256[] memory amounts = new uint256[](101);

        for (uint256 i = 0; i < 101; i++) {
            recipients[i] = makeAddr(string(abi.encodePacked("investor", i)));
            amounts[i] = 1 ether;
        }

        // 尝试批量铸造 (应该失败)
        vm.prank(agent);
        vm.expectRevert("Batch size too large");
        token.batchMint(recipients, amounts);
    }

    /**
     * @dev 测试 Identity claims 数量限制
     */
    function testIdentityClaimsLimit() public {
        address investor = makeAddr("investor");

        vm.prank(investor);
        Identity identity = new Identity(investor);

        // 创建多个 claim issuers 以测试 claims 数量限制
        // 当前 claimId 包含 issuer/topic/data/expiresAt/nonce,不同 claim 会独立计数
        ClaimIssuer[] memory issuers = new ClaimIssuer[](11);
        for (uint256 i = 0; i < 11; i++) {
            vm.prank(makeAddr(string(abi.encodePacked("issuerOwner", i))));
            issuers[i] = new ClaimIssuer();

            vm.prank(investor);
            identity.addTrustedIssuer(address(issuers[i]));
        }

        // 尝试添加 11 个不同 issuer 的 claims (相同 topic)
        for (uint256 i = 0; i < 11; i++) {
            bytes memory data = abi.encodePacked("CLAIM_", i);
            uint256 expiresAt = block.timestamp + 365 days;
            uint256 nonce = 0;

            // 使用不同的 issuer 私钥签名
            uint256 issuerPrivKey = i + 100;
            address issuerOwner = vm.addr(issuerPrivKey);

            // 将 issuer 所有权转移给 issuerOwner
            vm.prank(address(issuers[i]));
            // ClaimIssuer 没有 transferOwnership,所以我们直接用当前 owner 签名

            bytes32 messageHash = issuers[i].getSignedClaim(address(identity), 1, data, expiresAt, nonce);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
            bytes memory signature = abi.encodePacked(r, s, v);

            vm.prank(investor);
            if (i < 10) {
                identity.addClaim(1, 1, address(issuers[i]), signature, data, "", expiresAt, nonce);
            } else {
                vm.expectRevert("Identity: too many claims for this topic");
                identity.addClaim(1, 1, address(issuers[i]), signature, data, "", expiresAt, nonce);
            }
        }
    }
}
