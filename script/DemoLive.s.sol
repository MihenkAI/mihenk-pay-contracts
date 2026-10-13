// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MihenkPay} from "../src/MihenkPay.sol";

/// Live-network demo with a real stablecoin (no minting): sponsor locks, KOL accepts, Mihenk settles.
/// Env: PAY_CONTRACT, TOKEN, SPONSOR_KEY, KOL_KEY, VERIFIER_KEY,
///      AMOUNT (default 1 USDC = 1e6), DELIVERY_BPS (default 5000),
///      DELIVERED (default true), REACH_HIT (default true), TERMS_HASH, RESULT_HASH
contract DemoLive is Script {
    function run() external {
        MihenkPay pay = MihenkPay(vm.envAddress("PAY_CONTRACT"));
        IERC20 token = IERC20(vm.envAddress("TOKEN"));
        uint256 sponsorKey = vm.envUint("SPONSOR_KEY");
        uint256 kolKey = vm.envUint("KOL_KEY");
        uint256 verifierKey = vm.envUint("VERIFIER_KEY");
        uint128 amount = uint128(vm.envOr("AMOUNT", uint256(1e6)));
        uint16 deliveryBps = uint16(vm.envOr("DELIVERY_BPS", uint256(5_000)));
        bool delivered = vm.envOr("DELIVERED", true);
        bool reachHit = vm.envOr("REACH_HIT", true);
        bytes32 termsHash = vm.envOr("TERMS_HASH", keccak256("mihenk-demo-terms"));
        bytes32 resultHash = vm.envOr("RESULT_HASH", keccak256("mihenk-demo-report"));
        address kol = vm.addr(kolKey);

        vm.startBroadcast(sponsorKey);
        token.approve(address(pay), amount);
        uint256 id = pay.createCampaign(
            kol, address(token), amount, deliveryBps,
            uint40(block.timestamp + 1 days), uint40(block.timestamp + 7 days), termsHash
        );
        vm.stopBroadcast();
        console2.log("Campaign id:", id);

        vm.startBroadcast(kolKey);
        pay.acceptCampaign(id);
        vm.stopBroadcast();

        vm.startBroadcast(verifierKey);
        pay.settle(id, delivered, reachHit, resultHash);
        vm.stopBroadcast();
        console2.log("Settled. Run Finalize after the dispute window ends.");
    }
}
