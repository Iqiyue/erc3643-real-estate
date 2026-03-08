// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/compliance/TransferRestrictModule.sol";
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

contract ComplianceStateFlowTest is Test {
    ClaimIssuer public claimIssuer;
    IdentityRegistryStorage public identityStorage;
    IdentityRegistry public identityRegistry;
    ModularCompliance public compliance;
    TransferRestrictModule public transferRestrictModule;
    RealEstateToken public token;

    uint256 public issuerPrivateKey = 1;
    address public issuerOwner;
    address public investor1;
    address public investor2;

    function setUp() public {
        issuerOwner = vm.addr(issuerPrivateKey);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        vm.prank(issuerOwner);
        claimIssuer = new ClaimIssuer();
        identityStorage = new IdentityRegistryStorage();

        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;

        identityRegistry = new IdentityRegistry(address(identityStorage), trustedIssuers, claimTopics);
        identityStorage.bindIdentityRegistry(address(identityRegistry));

        transferRestrictModule = new TransferRestrictModule(0);
        compliance = new ModularCompliance();

        // HIGH-1 修复: 使用调度和执行模式
        compliance.scheduleAddModule(address(transferRestrictModule));
        vm.warp(block.timestamp + 2 days + 1);
        compliance.addModule(address(transferRestrictModule));

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

        _registerInvestor(investor1);
        _registerInvestor(investor2);
    }

    function testCanTransferIsPureCheckNoStateMutation() public view {
        assertEq(transferRestrictModule.holdingStartTime(investor1), 0);
        bool allowed = compliance.canTransfer(address(0), investor1, 100 ether);
        assertTrue(allowed);
        assertEq(transferRestrictModule.holdingStartTime(investor1), 0);
    }

    function testOnlyTokenCanCallPostTransferHook() public {
        vm.expectRevert("Only bound token");
        compliance.postTransferHook(address(0), investor1, 100 ether);
    }

    function testTransferUpdatesLockupStateOnlyAfterTransfer() public {
        token.mint(investor1, 1000 ether);
        assertGt(transferRestrictModule.holdingStartTime(investor1), 0);
        assertEq(transferRestrictModule.holdingStartTime(investor2), 0);

        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100 ether));

        assertEq(token.balanceOf(investor2), 100 ether);
        assertGt(transferRestrictModule.holdingStartTime(investor2), 0);
    }

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
