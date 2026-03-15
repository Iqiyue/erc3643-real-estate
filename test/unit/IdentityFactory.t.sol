// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/Identity.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/identity/IdentityFactory.sol";

contract IdentityFactoryTest is Test {
    IdentityFactory public factory;
    Identity public implementation;

    address public investor1;
    address public investor2;

    function setUp() public {
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        implementation = new Identity(address(0));
        factory = new IdentityFactory(address(implementation));
    }

    function testCreateIdentityInitializesOwner() public {
        address identityAddr = factory.createIdentity(investor1);
        Identity identity = Identity(identityAddr);

        assertEq(identity.owner(), investor1);
        assertTrue(identity.initialized());
        assertEq(factory.identityOf(investor1), identityAddr);
    }

    function testCreateIdentityCreatesDistinctClones() public {
        address identity1 = factory.createIdentity(investor1);
        address identity2 = factory.createIdentity(investor2);

        assertTrue(identity1 != identity2);
        assertEq(Identity(identity1).owner(), investor1);
        assertEq(Identity(identity2).owner(), investor2);
    }

    function testRevertWhen_CreateIdentityTwiceForSameUser() public {
        factory.createIdentity(investor1);

        vm.expectRevert("IdentityFactory: identity exists");
        factory.createIdentity(investor1);
    }

    function testRevertWhen_ReinitializeClone() public {
        address identityAddr = factory.createIdentity(investor1);

        vm.expectRevert("Identity: already initialized");
        Identity(identityAddr).initialize(investor2);
    }

    function testCreateIdentityDeterministicPredictsAddress() public {
        bytes32 salt = keccak256("investor1");
        address predicted = factory.predictIdentityDeterministic(salt);
        address created = factory.createIdentityDeterministic(investor1, salt);

        assertEq(created, predicted);
        assertEq(Identity(created).owner(), investor1);
    }
}
