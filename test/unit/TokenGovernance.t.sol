// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/governance/TokenGovernance.sol";

contract TokenGovernanceTest is Test {
    TokenGovernance public governance;

    address public owner1;
    address public owner2;
    address public owner3;
    address public nonOwner;

    function setUp() public {
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        nonOwner = makeAddr("nonOwner");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        governance = new TokenGovernance(owners, 2); // 需要 2/3 签名

        // 给治理合约一些 ETH
        vm.deal(address(governance), 10 ether);

        address recipient = makeAddr("recipient");
        address[] memory targets = new address[](5);
        bytes4[] memory selectors = new bytes4[](5);
        targets[0] = address(governance);
        targets[1] = address(governance);
        targets[2] = address(governance);
        targets[3] = address(0x123);
        targets[4] = recipient;
        selectors[0] = TokenGovernance.addOwner.selector;
        selectors[1] = TokenGovernance.removeOwner.selector;
        selectors[2] = TokenGovernance.changeRequirement.selector;
        selectors[3] = bytes4(0);
        selectors[4] = bytes4(0);

        vm.prank(owner1);
        governance.bootstrapWhitelist(targets, selectors);
    }

    function testInitialization() public view {
        assertEq(governance.required(), 2);
        assertTrue(governance.isOwner(owner1));
        assertTrue(governance.isOwner(owner2));
        assertTrue(governance.isOwner(owner3));
        assertFalse(governance.isOwner(nonOwner));
        assertTrue(governance.whitelistBootstrapped());
    }

    function testCannotBootstrapWhitelistTwice() public {
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        targets[0] = address(governance);
        selectors[0] = TokenGovernance.addOwner.selector;

        vm.prank(owner1);
        vm.expectRevert(TokenGovernance.WhitelistAlreadyBootstrapped.selector);
        governance.bootstrapWhitelist(targets, selectors);
    }

    function testRevertWhen_BootstrapWhitelistLengthMismatch() public {
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](2);
        targets[0] = address(governance);
        selectors[0] = TokenGovernance.addOwner.selector;
        selectors[1] = TokenGovernance.removeOwner.selector;

        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        TokenGovernance freshGovernance = new TokenGovernance(owners, 2);

        vm.prank(owner1);
        vm.expectRevert(TokenGovernance.LengthMismatch.selector);
        freshGovernance.bootstrapWhitelist(targets, selectors);
    }

    function testRevertWhen_BootstrapWhitelistContainsZeroTarget() public {
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        targets[0] = address(0);
        selectors[0] = bytes4(0);

        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        TokenGovernance freshGovernance = new TokenGovernance(owners, 2);

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(TokenGovernance.InvalidTarget.selector, address(0)));
        freshGovernance.bootstrapWhitelist(targets, selectors);
    }

    function testSubmitProposal() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Send 1 ETH to address"
        );

        assertEq(proposalId, 0);

        (
            address target,
            ,
            uint256 value,
            string memory description,
            uint256 confirmations,
            bool executed
        ) = governance.getProposal(proposalId);

        assertEq(target, address(0x123));
        assertEq(value, 1 ether);
        assertEq(description, "Send 1 ETH to address");
        assertEq(confirmations, 0);
        assertFalse(executed);
    }

    function testConfirmProposal() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test proposal"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        (,,,, uint256 confirmations,) = governance.getProposal(proposalId);
        assertEq(confirmations, 1);
        assertTrue(governance.isProposalConfirmed(proposalId, owner1));
    }

    function testExecuteProposal() public {
        address recipient = makeAddr("recipient");

        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            recipient,
            "",
            1 ether,
            "Send 1 ETH"
        );

        // 第一个确认
        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        // 第二个确认
        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        // 将提案加入队列
        vm.prank(owner1);
        governance.queueProposal(proposalId);

        // 等待时间锁过期 (2 days)
        vm.warp(block.timestamp + 2 days + 1);

        uint256 balanceBefore = recipient.balance;

        // 执行提案
        vm.prank(owner1);
        governance.executeProposal(proposalId);

        uint256 balanceAfter = recipient.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);

        (,,,,, bool executed) = governance.getProposal(proposalId);
        assertTrue(executed);
    }

    function testCannotExecuteWithoutEnoughConfirmations() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        // 只有1个确认,需要2个,排队应该失败
        vm.prank(owner1);
        vm.expectRevert("Not enough confirmations");
        governance.queueProposal(proposalId);
    }

    function testRevokeConfirmation() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        (,,,, uint256 confirmationsBefore,) = governance.getProposal(proposalId);
        assertEq(confirmationsBefore, 1);

        vm.prank(owner1);
        governance.revokeConfirmation(proposalId);

        (,,,, uint256 confirmationsAfter,) = governance.getProposal(proposalId);
        assertEq(confirmationsAfter, 0);
        assertFalse(governance.isProposalConfirmed(proposalId, owner1));
    }

    function testCannotRevokeAfterQueue() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        vm.prank(owner1);
        vm.expectRevert("Cannot revoke after queued");
        governance.revokeConfirmation(proposalId);
    }

    function testNonOwnerCannotSubmitProposal() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(TokenGovernance.Unauthorized.selector, nonOwner)
        );
        governance.submitProposal(address(0x123), "", 1 ether, "Test");
    }

    function testRevertWhen_SubmitProposalTargetNotAllowed() public {
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(TokenGovernance.TargetNotAllowed.selector, address(0x456)));
        governance.submitProposal(address(0x456), "", 1 ether, "Target not whitelisted");
    }

    function testRevertWhen_SubmitProposalFunctionNotAllowed() public {
        bytes memory removeData = abi.encodeWithSelector(TokenGovernance.removeOwner.selector, owner3);
        vm.prank(owner1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenGovernance.FunctionNotAllowed.selector,
                address(0x123),
                TokenGovernance.removeOwner.selector
            )
        );
        governance.submitProposal(address(0x123), removeData, 0, "Function not whitelisted");
    }

    function testNonOwnerCannotConfirmProposal() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test"
        );

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(TokenGovernance.Unauthorized.selector, nonOwner)
        );
        governance.confirmProposal(proposalId);
    }

    function testCannotConfirmTwice() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(0x123),
            "",
            1 ether,
            "Test"
        );

        vm.startPrank(owner1);
        governance.confirmProposal(proposalId);

        vm.expectRevert("Already confirmed");
        governance.confirmProposal(proposalId);
        vm.stopPrank();
    }

    function testCannotExecuteTwice() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            makeAddr("recipient"),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner1);
        governance.executeProposal(proposalId);

        vm.prank(owner1);
        vm.expectRevert("Already executed");
        governance.executeProposal(proposalId);
    }

    function testAddOwnerThroughGovernance() public {
        address newOwner = makeAddr("newOwner");

        bytes memory data = abi.encodeWithSelector(
            TokenGovernance.addOwner.selector,
            newOwner
        );

        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(governance),
            data,
            0,
            "Add new owner"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner1);
        governance.executeProposal(proposalId);

        assertTrue(governance.isOwner(newOwner));
    }

    function testChangeRequirementThroughGovernance() public {
        bytes memory data = abi.encodeWithSelector(
            TokenGovernance.changeRequirement.selector,
            3
        );

        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            address(governance),
            data,
            0,
            "Change requirement to 3"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner1);
        governance.executeProposal(proposalId);

        assertEq(governance.required(), 3);
    }

    function testGetOwners() public view {
        address[] memory owners = governance.getOwners();
        assertEq(owners.length, 3);
        assertEq(owners[0], owner1);
        assertEq(owners[1], owner2);
        assertEq(owners[2], owner3);
    }

    function testCannotExecuteWithoutQueue() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            makeAddr("recipient"),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        // 尝试直接执行,应该失败
        vm.prank(owner1);
        vm.expectRevert(
            abi.encodeWithSelector(TokenGovernance.ProposalNotQueued.selector, proposalId)
        );
        governance.executeProposal(proposalId);
    }

    function testCannotExecuteBeforeTimelock() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            makeAddr("recipient"),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        // 尝试在时间锁到期前执行
        vm.warp(block.timestamp + 1 days);

        vm.prank(owner1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenGovernance.TimelockNotExpired.selector,
                proposalId,
                block.timestamp + 1 days
            )
        );
        governance.executeProposal(proposalId);
    }

    function testCannotExecuteAfterGracePeriod() public {
        vm.prank(owner1);
        uint256 proposalId = governance.submitProposal(
            makeAddr("recipient"),
            "",
            1 ether,
            "Test"
        );

        vm.prank(owner1);
        governance.confirmProposal(proposalId);

        vm.prank(owner2);
        governance.confirmProposal(proposalId);

        vm.prank(owner1);
        governance.queueProposal(proposalId);

        // 等待超过宽限期 (2 days + 7 days)
        vm.warp(block.timestamp + 10 days);

        vm.prank(owner1);
        vm.expectRevert(
            abi.encodeWithSelector(TokenGovernance.ProposalExpired.selector, proposalId)
        );
        governance.executeProposal(proposalId);
    }
}
