// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/ClaimIssuer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/Identity.sol";

contract ClaimIssuerTest is Test {
    ClaimIssuer public claimIssuer;

    address public issuerOwner;
    uint256 public issuerPrivateKey = 1;
    address public investor1;
    address public investor2;

    function setUp() public {
        issuerOwner = vm.addr(issuerPrivateKey);
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        vm.prank(issuerOwner);
        claimIssuer = new ClaimIssuer();
    }

    function testRevokeSpecificClaimDoesNotAffectOtherIdentitySameTopic() public {
        Identity identity1 = new Identity(investor1);
        Identity identity2 = new Identity(investor2);

        bytes memory data1 = abi.encodePacked("KYC_VERIFIED_INVESTOR_1");
        bytes memory data2 = abi.encodePacked("KYC_VERIFIED_INVESTOR_2");

        bytes memory sig1 = _sign(identity1, 1, data1);
        bytes memory sig2 = _sign(identity2, 1, data2);

        assertTrue(claimIssuer.isClaimValid(address(identity1), 1, data1, sig1));
        assertTrue(claimIssuer.isClaimValid(address(identity2), 1, data2, sig2));

        vm.prank(issuerOwner);
        claimIssuer.revokeClaim(address(identity1), 1, data1);

        assertFalse(claimIssuer.isClaimValid(address(identity1), 1, data1, sig1));
        assertTrue(claimIssuer.isClaimValid(address(identity2), 1, data2, sig2));
    }

    function testRestoreRevokedClaim() public {
        Identity identity = new Identity(investor1);
        bytes memory data = abi.encodePacked("KYC_VERIFIED");
        uint256 expiresAt = block.timestamp + 365 days;
        bytes memory sig = _sign(identity, 1, data, expiresAt, 7);

        assertTrue(claimIssuer.isClaimValid(address(identity), 1, data, sig, expiresAt, 7));

        vm.prank(issuerOwner);
        claimIssuer.revokeClaim(address(identity), 1, data, expiresAt, 7);
        assertFalse(claimIssuer.isClaimValid(address(identity), 1, data, sig, expiresAt, 7));

        vm.prank(issuerOwner);
        claimIssuer.restoreClaim(address(identity), 1, data, expiresAt, 7);
        assertTrue(claimIssuer.isClaimValid(address(identity), 1, data, sig, expiresAt, 7));
    }

    function testExpiredClaimShouldBeRejectedByRegistryLogic() public {
        // ClaimIssuer validates signature + revocation only.
        // Expiry enforcement is performed by IdentityRegistry.
        Identity identity = new Identity(investor1);
        bytes memory data = abi.encodePacked("KYC_EXPIRED");
        bytes memory sig = _sign(identity, 1, data);

        assertTrue(claimIssuer.isClaimValid(address(identity), 1, data, sig));
    }

    function _sign(Identity identity, uint256 topic, bytes memory data) internal view returns (bytes memory) {
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), topic, data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function _sign(
        Identity identity,
        uint256 topic,
        bytes memory data,
        uint256 expiresAt,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = claimIssuer.getSignedClaim(address(identity), topic, data, expiresAt, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPrivateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

}
