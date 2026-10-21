// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// USDC-style blacklist: transfers from or to a blacklisted address revert.
contract BlacklistUSD is MockUSD {
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
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
    BlacklistUSD usd;

    address owner = makeAddr("owner");
    address verifier = makeAddr("verifier");
    address treasury = makeAddr("treasury");
    address sponsor = makeAddr("sponsor");
    address kol = makeAddr("kol");
    address stranger = makeAddr("stranger");

    uint128 constant AMOUNT = 2_000e6; // 2,000 USD
    uint16 constant FEE = 300; // 3%
    uint40 constant LIVE = 1 days; // agreed time the post stays live
    uint256 constant START = 10_000e6;

    function setUp() public {
        pay = new MihenkPay(owner, verifier, treasury, FEE);
        usd = new BlacklistUSD();
        vm.prank(owner);
        pay.setTokenAllowed(address(usd), true);
        usd.mint(sponsor, START);
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
            LIVE,
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

    /// Accepted, post live for the agreed time, settled.
    function _settled(uint16 deliveryBps, bool delivered, bool reach) internal returns (uint256 id) {
        id = _createAccepted(deliveryBps);
        vm.warp(block.timestamp + LIVE);
        vm.prank(verifier);
        pay.settle(id, delivered, reach, keccak256("report"));
    }

    function _fee(uint256 gross) internal pure returns (uint256) {
        return (gross * FEE) / 10_000;
    }

    // ------------------------------------------------------------ happy paths

    function test_FullPayout() public {
        uint256 id = _settled(5_000, true, true);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        assertEq(usd.balanceOf(kol), AMOUNT - _fee(AMOUNT));
        assertEq(usd.balanceOf(treasury), _fee(AMOUNT));
        assertEq(usd.balanceOf(sponsor), START - AMOUNT);
        assertEq(usd.balanceOf(address(pay)), 0);
    }

    function test_DeliveryOnly_HalfRefunded() public {
        uint256 id = _settled(5_000, true, false);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        uint256 gross = AMOUNT / 2;
        assertEq(usd.balanceOf(kol), gross - _fee(gross));
        assertEq(usd.balanceOf(treasury), _fee(gross));
        assertEq(usd.balanceOf(sponsor), START - gross);
    }

    function test_NotDelivered_FullRefund_ReachIgnored() public {
        uint256 id = _settled(5_000, false, true);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(kol), 0);
        assertEq(usd.balanceOf(treasury), 0);
        assertEq(usd.balanceOf(sponsor), START);
    }

    // --------------------------------------------------------------- disputes

    function test_DisputeAndResolve() public {
        uint256 id = _settled(5_000, true, false);
        vm.prank(kol);
        pay.dispute(id);

        vm.prank(owner);
        pay.resolveDispute(id, AMOUNT, keccak256("corrected"));

        assertEq(usd.balanceOf(kol), AMOUNT - _fee(AMOUNT));
        assertEq(uint8(pay.getCampaign(id).status), uint8(MihenkPay.Status.Closed));
    }

    function test_UnresolvedDispute_FallsBackAfterTimeout() public {
        uint256 id = _settled(5_000, true, true);
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
        uint256 id = _settled(5_000, true, true);
        vm.warp(block.timestamp + 3 days);
        vm.prank(kol);
        vm.expectRevert(MihenkPay.TooLate.selector);
        pay.dispute(id);
    }

    function test_FinalizeBeforeWindow_Reverts() public {
        uint256 id = _settled(5_000, true, true);
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.finalize(id);
    }

    function test_DisputeWindow_AtLeast24Hours() public {
        vm.startPrank(owner);
        vm.expectRevert(MihenkPay.InvalidWindow.selector);
        pay.setDisputeWindow(1 hours);
        vm.expectRevert(MihenkPay.InvalidWindow.selector);
        pay.setDisputeWindow(24 hours - 1);
        pay.setDisputeWindow(24 hours);
        vm.stopPrank();
        assertEq(pay.disputeWindow(), 24 hours);
    }

    // ---------------------------------------------------- refunds & cancel

    function test_CancelBeforeAccept() public {
        uint256 id = _create(5_000);
        vm.prank(sponsor);
        pay.cancelBeforeAccept(id);
        assertEq(usd.balanceOf(sponsor), START);
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
        assertEq(usd.balanceOf(sponsor), START);
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

    // ------------------------------------------------------ minimum time live

    function test_SettleBeforeMinLive_Reverts() public {
        uint256 id = _createAccepted(5_000);
        vm.warp(block.timestamp + LIVE - 1);
        vm.prank(verifier);
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.settle(id, true, true, bytes32(0));

        vm.warp(block.timestamp + 1);
        vm.prank(verifier);
        pay.settle(id, true, true, bytes32(0));
        assertEq(uint8(pay.getCampaign(id).status), uint8(MihenkPay.Status.Settled));
    }

    function test_MinLiveCountsFromAcceptance() public {
        uint256 id = _create(5_000);
        vm.warp(block.timestamp + 1 days + 12 hours); // KOL accepts late
        vm.prank(kol);
        pay.acceptCampaign(id);
        vm.warp(block.timestamp + LIVE - 1);
        vm.prank(verifier);
        vm.expectRevert(MihenkPay.TooEarly.selector);
        pay.settle(id, true, true, bytes32(0));
    }

    function test_MinLiveMustFitBeforeSettleDeadline() public {
        vm.prank(sponsor);
        vm.expectRevert(MihenkPay.InvalidDeadlines.selector);
        pay.createCampaign(
            kol,
            address(usd),
            AMOUNT,
            5_000,
            7 days,
            uint40(block.timestamp + 2 days),
            uint40(block.timestamp + 9 days), // post deadline + 7 days = settle deadline: no room
            0
        );
    }

    // --------------------------------------------------------- access control

    function test_OnlyVerifierSettles() public {
        uint256 id = _createAccepted(5_000);
        vm.warp(block.timestamp + LIVE);
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
        uint256 id = _settled(5_000, true, true);
        vm.prank(stranger);
        vm.expectRevert(MihenkPay.NotParty.selector);
        pay.dispute(id);
    }

    function test_CannotSettleTwice() public {
        uint256 id = _settled(5_000, true, true);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(MihenkPay.WrongStatus.selector, MihenkPay.Status.Settled));
        pay.settle(id, true, true, bytes32(0));
    }

    // ------------------------------------------------------------ guard rails

    function test_FeeRateSnapshottedAtCreation() public {
        uint256 id = _createAccepted(5_000);
        vm.prank(owner);
        pay.setFee(1_000, treasury);
        vm.warp(block.timestamp + LIVE);
        vm.prank(verifier);
        pay.settle(id, true, true, bytes32(0));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(treasury), _fee(AMOUNT));
    }

    function test_FeeRecipientSnapshottedAtCreation() public {
        address newTreasury = makeAddr("newTreasury");
        uint256 id = _createAccepted(5_000);
        vm.prank(owner);
        pay.setFee(FEE, newTreasury);
        vm.warp(block.timestamp + LIVE);
        vm.prank(verifier);
        pay.settle(id, true, true, bytes32(0));
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);
        assertEq(usd.balanceOf(treasury), _fee(AMOUNT));
        assertEq(usd.balanceOf(newTreasury), 0);
        assertEq(pay.getCampaign(id).feeRecipient, treasury);
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
            kol, address(other), AMOUNT, 5_000, 0, uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), 0
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
            kol, address(ft), 100e18, 5_000, 0, uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), 0
        );
        vm.stopPrank();
    }

    function test_BadDeadlines_Revert() public {
        vm.prank(sponsor);
        vm.expectRevert(MihenkPay.InvalidDeadlines.selector);
        pay.createCampaign(
            kol, address(usd), AMOUNT, 5_000, 0, uint40(block.timestamp + 2 days), uint40(block.timestamp + 1 days), 0
        );
    }

    // ------------------------------------------- blacklisted recipients (v2)

    function test_BlacklistedKol_OthersStillPaid_KolClaimsLater() public {
        uint256 id = _settled(5_000, true, false); // half earned
        usd.setBlacklisted(kol, true);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id); // v1 reverted here and the funds stayed locked

        uint256 gross = AMOUNT / 2;
        uint256 kolNet = gross - _fee(gross);
        assertEq(usd.balanceOf(sponsor), START - gross); // refund arrived
        assertEq(usd.balanceOf(treasury), _fee(gross)); // fee arrived
        assertEq(pay.owed(address(usd), kol), kolNet); // KOL share credited
        assertEq(usd.balanceOf(address(pay)), kolNet);

        // While blacklisted the KOL cannot withdraw, and nobody else can take it.
        vm.prank(kol);
        vm.expectRevert();
        pay.claim(IERC20(address(usd)));
        vm.prank(stranger);
        vm.expectRevert(MihenkPay.NothingToClaim.selector);
        pay.claim(IERC20(address(usd)));

        usd.setBlacklisted(kol, false);
        vm.prank(kol);
        pay.claim(IERC20(address(usd)));
        assertEq(usd.balanceOf(kol), kolNet);
        assertEq(pay.owed(address(usd), kol), 0);
        assertEq(usd.balanceOf(address(pay)), 0);
    }

    function test_BlacklistedSponsor_KolStillPaid() public {
        uint256 id = _settled(5_000, true, false);
        usd.setBlacklisted(sponsor, true);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        uint256 gross = AMOUNT / 2;
        assertEq(usd.balanceOf(kol), gross - _fee(gross));
        assertEq(usd.balanceOf(treasury), _fee(gross));
        assertEq(pay.owed(address(usd), sponsor), AMOUNT - gross);
    }

    function test_BlacklistedFeeRecipient_PartiesStillPaid() public {
        uint256 id = _settled(5_000, true, false);
        usd.setBlacklisted(treasury, true);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id);

        uint256 gross = AMOUNT / 2;
        assertEq(usd.balanceOf(kol), gross - _fee(gross));
        assertEq(usd.balanceOf(sponsor), START - gross);
        assertEq(pay.owed(address(usd), treasury), _fee(gross));
    }

    function test_BlacklistedKol_DuringDisputeResolution() public {
        uint256 id = _settled(5_000, true, true);
        vm.prank(sponsor);
        pay.dispute(id);
        usd.setBlacklisted(kol, true);
        vm.prank(owner);
        pay.resolveDispute(id, AMOUNT / 2, keccak256("corrected"));

        uint256 gross = AMOUNT / 2;
        assertEq(usd.balanceOf(sponsor), START - gross);
        assertEq(pay.owed(address(usd), kol), gross - _fee(gross));
        assertEq(uint8(pay.getCampaign(id).status), uint8(MihenkPay.Status.Closed));
    }

    function test_BlacklistedSponsor_RefundExpiredCredited() public {
        uint256 id = _createAccepted(5_000);
        usd.setBlacklisted(sponsor, true);
        vm.warp(block.timestamp + 12 days + 1);
        pay.refundExpired(id);
        assertEq(pay.owed(address(usd), sponsor), AMOUNT);
        assertEq(uint8(pay.getCampaign(id).status), uint8(MihenkPay.Status.Refunded));
    }

    function test_ClaimNothing_Reverts() public {
        vm.prank(kol);
        vm.expectRevert(MihenkPay.NothingToClaim.selector);
        pay.claim(IERC20(address(usd)));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ConservationOfFunds(
        uint128 amount,
        uint16 deliveryBps,
        uint40 minLive,
        bool delivered,
        bool reach,
        bool blockKol,
        bool blockSponsor,
        bool blockTreasury
    ) public {
        amount = uint128(bound(amount, 1, START));
        deliveryBps = uint16(bound(deliveryBps, 0, 10_000));
        minLive = uint40(bound(minLive, 0, 30 days));
        vm.prank(sponsor);
        uint256 id = pay.createCampaign(
            kol,
            address(usd),
            amount,
            deliveryBps,
            minLive,
            uint40(block.timestamp + 1 days),
            uint40(block.timestamp + 1 days + minLive + 1 days),
            0
        );
        vm.prank(kol);
        pay.acceptCampaign(id);
        vm.warp(block.timestamp + minLive);
        vm.prank(verifier);
        pay.settle(id, delivered, reach, 0);

        usd.setBlacklisted(kol, blockKol);
        usd.setBlacklisted(sponsor, blockSponsor);
        usd.setBlacklisted(treasury, blockTreasury);
        vm.warp(block.timestamp + 3 days);
        pay.finalize(id); // never reverts, whoever is blacklisted

        uint256 owedKol = pay.owed(address(usd), kol);
        uint256 owedSponsor = pay.owed(address(usd), sponsor);
        uint256 owedTreasury = pay.owed(address(usd), treasury);
        // Everything still in the contract is credited to someone; nothing is stuck.
        assertEq(usd.balanceOf(address(pay)), owedKol + owedSponsor + owedTreasury);
        assertEq(
            usd.balanceOf(kol) + usd.balanceOf(treasury) + usd.balanceOf(sponsor) + owedKol + owedSponsor
                + owedTreasury,
            START
        );

        // Once unblocked, everyone can claim and the contract is empty.
        usd.setBlacklisted(kol, false);
        usd.setBlacklisted(sponsor, false);
        usd.setBlacklisted(treasury, false);
        if (owedKol > 0) {
            vm.prank(kol);
            pay.claim(IERC20(address(usd)));
        }
        if (owedSponsor > 0) {
            vm.prank(sponsor);
            pay.claim(IERC20(address(usd)));
        }
        if (owedTreasury > 0) {
            vm.prank(treasury);
            pay.claim(IERC20(address(usd)));
        }
        assertEq(usd.balanceOf(address(pay)), 0);
        assertEq(usd.balanceOf(kol) + usd.balanceOf(treasury) + usd.balanceOf(sponsor), START);
    }
}
