// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MihenkPay} from "../src/MihenkPay.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burnt = value / 100;
            super._update(from, address(0), burnt);
            super._update(from, to, value - burnt);
        } else {
            super._update(from, to, value);
        }
    }
}

contract MihenkPayTest is Test {
    MihenkPay pay;
    MockUSD usd;

    address owner = makeAddr("owner");
    address verifier = makeAddr("verifier");
    address treasury = makeAddr("treasury");
    address sponsor = makeAddr("sponsor");
    address kol = makeAddr("kol");
    address stranger = makeAddr("stranger");

    uint128 constant AMOUNT = 2_000e6; // 2,000 USD
    uint16 constant FEE = 300; // 3%

    function setUp() public {
        pay = new MihenkPay(owner, verifier, treasury, FEE);
        usd = new MockUSD();
        vm.prank(owner);
        pay.setTokenAllowed(address(usd), true);
        usd.mint(sponsor, 10_000e6);
        vm.prank(sponsor);
        usd.approve(address(pay), type(uint256).max);
    }

    function _create(uint16 deliveryBps) internal returns (uint256 id) {
        vm.prank(sponsor);
        id = pay.createCampaign(
            kol,
            address(usd),
            AMOUNT,
            deliveryBps,
            uint40(block.timestamp + 2 days),
            uint40(block.timestamp + 12 days),
            keccak256("terms")
        );
    }

    function _createAccepted(uint16 deliveryBps) internal returns (uint256 id) {
        id = _create(deliveryBps);
        vm.prank(kol);
        pay.acceptCampaign(id);
    }

    // ------------------------------------------------------------ happy paths

    function test_FullPayout() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, true, keccak256("report"));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        uint256 fee = (uint256(AMOUNT) * FEE) / 10_000;
        assertEq(usd.balanceOf(kol), AMOUNT - fee);
        assertEq(usd.balanceOf(treasury), fee);
        assertEq(usd.balanceOf(sponsor), 10_000e6 - AMOUNT);
        assertEq(usd.balanceOf(address(pay)), 0);
    }

    function test_DeliveryOnly_HalfRefunded() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, false, keccak256("report"));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        uint256 gross = AMOUNT / 2;
        uint256 fee = (gross * FEE) / 10_000;
        assertEq(usd.balanceOf(kol), gross - fee);
        assertEq(usd.balanceOf(treasury), fee);
        assertEq(usd.balanceOf(sponsor), 10_000e6 - gross);
    }

    function test_NotDelivered_FullRefund_ReachIgnored() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, false, true, keccak256("report"));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(kol), 0);
        assertEq(usd.balanceOf(treasury), 0);
        assertEq(usd.balanceOf(sponsor), 10_000e6);
    }

    // --------------------------------------------------------------- disputes

    function test_DisputeAndResolve() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, false, keccak256("report"));
        vm.prank(kol);
        pay.dispute(id);

        vm.prank(owner);
        pay.resolveDispute(id, AMOUNT, keccak256("corrected"));

        uint256 fee = (uint256(AMOUNT) * FEE) / 10_000;
        assertEq(usd.balanceOf(kol), AMOUNT - fee);
        assertEq(uint8(pay.getCampaign(id).status), uint8(MihenkPay.Status.Closed));
    }

    function test_UnresolvedDispute_FallsBackAfterTimeout() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, true, keccak256("report"));
        vm.prank(sponsor);
        pay.dispute(id);

        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.finalize(id);

        vm.warp(block.timestamp + 30 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(address(pay)), 0);
    }

    function test_DisputeAfterWindow_Reverts() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, true, keccak256("report"));
        vm.warp(block.timestamp + 3 days);
        vm.prank(kol);
        vm.expectRevert(MihenkPay.TooLate.selector);
        pay.dispute(id);
    }

    function test_FinalizeBeforeWindow_Reverts() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, true, keccak256("report"));
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.finalize(id);
    }

    // ---------------------------------------------------- refunds & cancel

    function test_CancelBeforeAccept() public {
        uint256 id = _create(5_000);
        vm.prank(sponsor);
        pay.cancelBeforeAccept(id);
        assertEq(usd.balanceOf(sponsor), 10_000e6);
    }

    function test_CancelAfterAccept_Reverts() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(MihenkPay.WrongStatus.selector, MihenkPay.Status.Accepted));
        pay.cancelBeforeAccept(id);
    }

    function test_RefundExpired_WhenNeverSettled() public {
        uint256 id = _createAccepted(5_000);
        vm.warp(block.timestamp + 12 days + 1);
        vm.prank(stranger);
        pay.refundExpired(id);
        assertEq(usd.balanceOf(sponsor), 10_000e6);
    }

    function test_RefundExpired_TooEarly() public {
        uint256 id = _createAccepted(5_000);
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.refundExpired(id);
    }

    function test_SettleAfterDeadline_Reverts() public {
        uint256 id = _createAccepted(5_000);
        vm.warp(block.timestamp + 12 days + 1);
        vm.prank(verifier);
        vm.expectRevert(MihenkPay.TooLate.selector);
        pay.settle(id, true, true, bytes32(0));
    }

    function test_AcceptAfterPostDeadline_Reverts() public {
        uint256 id = _create(5_000);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(kol);
        vm.expectRevert(MihenkPay.TooLate.selector);
        pay.acceptCampaign(id);
    }

    // --------------------------------------------------------- access control

    function test_OnlyVerifierSettles() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(stranger);
        vm.expectRevert(MihenkPay.NotVerifier.selector);
        pay.settle(id, true, true, bytes32(0));
    }

    function test_OnlyKolAccepts() public {
        uint256 id = _create(5_000);
        vm.prank(stranger);
        vm.expectRevert(MihenkPay.NotKol.selector);
        pay.acceptCampaign(id);
    }

    function test_OnlyPartiesDispute() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(verifier);
        pay.settle(id, true, true, bytes32(0));
        vm.prank(stranger);
        vm.expectRevert(MihenkPay.NotParty.selector);
        pay.dispute(id);
    }

    function test_CannotSettleTwice() public {
        uint256 id = _createAccepted(5_000);
        vm.startPrank(verifier);
        pay.settle(id, true, true, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(MihenkPay.WrongStatus.selector, MihenkPay.Status.Settled));
        pay.settle(id, true, true, bytes32(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ guard rails

    function test_FeeSnapshottedAtCreation() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(owner);
        pay.setFee(1_000, treasury);
        vm.prank(verifier);
        pay.settle(id, true, true, bytes32(0));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(treasury), (uint256(AMOUNT) * FEE) / 10_000);
    }

    function test_FeeCap() public {
        vm.prank(owner);
        vm.expectRevert(MihenkPay.InvalidBps.selector);
        pay.setFee(1_001, treasury);
    }

    function test_DisallowedToken_Reverts() public {
        MockUSD other = new MockUSD();
        vm.prank(sponsor);
        vm.expectRevert(MihenkPay.TokenNotAllowed.selector);
        pay.createCampaign(
            kol, address(other), AMOUNT, 5_000, uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), 0
        );
    }

    function test_FeeOnTransferToken_Rejected() public {
        FeeToken ft = new FeeToken();
        vm.prank(owner);
        pay.setTokenAllowed(address(ft), true);
        ft.mint(sponsor, 1_000e18);
        vm.startPrank(sponsor);
        ft.approve(address(pay), type(uint256).max);
        vm.expectRevert(MihenkPay.FeeOnTransferToken.selector);
        pay.createCampaign(
            kol, address(ft), 100e18, 5_000, uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), 0
        );
        vm.stopPrank();
    }

    function test_BadDeadlines_Revert() public {
        vm.prank(sponsor);
        vm.expectRevert(MihenkPay.InvalidDeadlines.selector);
        pay.createCampaign(
            kol, address(usd), AMOUNT, 5_000, uint40(block.timestamp + 2 days), uint40(block.timestamp + 1 days), 0
        );
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ConservationOfFunds(uint128 amount, uint16 deliveryBps, bool delivered, bool reach) public {
        amount = uint128(bound(amount, 1, 10_000e6));
        deliveryBps = uint16(bound(deliveryBps, 0, 10_000));
        vm.prank(sponsor);
        uint256 id = pay.createCampaign(
            kol,
            address(usd),
            amount,
            deliveryBps,
            uint40(block.timestamp + 1 days),
            uint40(block.timestamp + 5 days),
            0
        );
        vm.prank(kol);
        pay.acceptCampaign(id);
        vm.prank(verifier);
        pay.settle(id, delivered, reach, 0);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        assertEq(usd.balanceOf(address(pay)), 0);
        assertEq(usd.balanceOf(kol) + usd.balanceOf(treasury) + usd.balanceOf(sponsor), 10_000e6);
    }
}
