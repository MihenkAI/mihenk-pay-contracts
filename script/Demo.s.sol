// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {TestUSD} from "../src/TestUSD.sol";

/// End-to-end demo on a testnet: sponsor locks, KOL accepts, Mihenk settles.
/// Env: PAY_CONTRACT, TOKEN (TestUSD), SPONSOR_KEY, KOL_KEY, VERIFIER_KEY,
///      AMOUNT (default 2000 tUSD), DELIVERY_BPS (default 5000),
///      MIN_LIVE (seconds after acceptance before settlement; default 0 so the demo settles at once),
///      DELIVERED (default true), REACH_HIT (default true),
///      TERMS_HASH, RESULT_HASH (keccak of the off-chain terms / Mihenk report)
contract Demo is Script {
    function run() external {
        MihenkPay pay = MihenkPay(vm.envAddress("PAY_CONTRACT"));
        TestUSD token = TestUSD(vm.envAddress("TOKEN"));
        uint256 sponsorKey = vm.envUint("SPONSOR_KEY");
        uint256 kolKey = vm.envUint("KOL_KEY");
        uint256 verifierKey = vm.envUint("VERIFIER_KEY");
        uint128 amount = uint128(vm.envOr("AMOUNT", uint256(2_000e6)));
        uint16 deliveryBps = uint16(vm.envOr("DELIVERY_BPS", uint256(5_000)));
        uint40 minLive = uint40(vm.envOr("MIN_LIVE", uint256(0)));
        bool delivered = vm.envOr("DELIVERED", true);
        bool reachHit = vm.envOr("REACH_HIT", true);
        bytes32 termsHash = vm.envOr("TERMS_HASH", keccak256("mihenk-demo-terms"));
        bytes32 resultHash = vm.envOr("RESULT_HASH", keccak256("mihenk-demo-report"));
        address kol = vm.addr(kolKey);

        // 1. Sponsor funds and locks the KOL fee
        vm.startBroadcast(sponsorKey);
        token.mint(vm.addr(sponsorKey), amount);
        token.approve(address(pay), amount);
        uint256 id = pay.createCampaign(
            kol, address(token), amount, deliveryBps, minLive,
            uint40(block.timestamp + 1 days), uint40(block.timestamp + 7 days + minLive), termsHash
        );
        vm.stopBroadcast();
        console2.log("Campaign id:", id);

        // 2. KOL accepts from the payout wallet
        vm.startBroadcast(kolKey);
        pay.acceptCampaign(id);
        vm.stopBroadcast();

        // 3. Mihenk verifier settles with the measured result
        vm.startBroadcast(verifierKey);
        pay.settle(id, delivered, reachHit, resultHash);
        vm.stopBroadcast();

        console2.log("Settled. Run Finalize after the dispute window ends.");
    }
}
