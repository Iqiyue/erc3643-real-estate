// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./Identity.sol";

contract IdentityFactory is Ownable {
    using Clones for address;

    address public immutable implementation;
    mapping(address => address) public identityOf;

    event IdentityCreated(address indexed user, address indexed identity);

    constructor(address _implementation) Ownable(msg.sender) {
        require(_implementation != address(0), "IdentityFactory: invalid implementation");
        implementation = _implementation;
    }

    function createIdentity(address user) external onlyOwner returns (address identity) {
        require(user != address(0), "IdentityFactory: invalid user");
        require(identityOf[user] == address(0), "IdentityFactory: identity exists");

        identity = Clones.clone(implementation);
        Identity(identity).initialize(user);
        identityOf[user] = identity;

        emit IdentityCreated(user, identity);
    }

    function createIdentityDeterministic(address user, bytes32 salt) external onlyOwner returns (address identity) {
        require(user != address(0), "IdentityFactory: invalid user");
        require(identityOf[user] == address(0), "IdentityFactory: identity exists");

        identity = Clones.cloneDeterministic(implementation, salt);
        Identity(identity).initialize(user);
        identityOf[user] = identity;

        emit IdentityCreated(user, identity);
    }

    function predictIdentityDeterministic(bytes32 salt) external view returns (address predicted) {
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }
}
