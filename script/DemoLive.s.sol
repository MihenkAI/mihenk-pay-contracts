// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {BuilderCode} from "./BuilderCode.sol";

/// Live-network demo with a real stablecoin (no minting): sponsor locks, KOL accepts, Mihenk settles.
/// On Base mainnet every transaction carries Mihenk AI's Builder Code (see BuilderCode.sol).
/// Env: PAY_CONTRACT, TOKEN, SPONSOR_KEY, KOL_KEY, VERIFIER_KEY,
///      AMOUNT (default 1 USDC = 1e6), DELIVERY_BPS (default 5000),
///      MIN_LIVE (seconds after acceptance before settlement; default 0 so the demo settles at once),
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
        uint40 minLive = uint40(vm.envOr("MIN_LIVE", uint256(0)));
        bool delivered = vm.envOr("DELIVERED", true);
        bool reachHit = vm.envOr("REACH_HIT", true);
        bytes32 termsHash = vm.envOr("TERMS_HASH", keccak256("mihenk-demo-terms"));
        bytes32 resultHash = vm.envOr("RESULT_HASH", keccak256("mihenk-demo-report"));
        address kol = vm.addr(kolKey);

        vm.startBroadcast(sponsorKey);
        BuilderCode.exec(address(token), abi.encodeCall(IERC20.approve, (address(pay), uint256(amount))));
        bytes memory ret = BuilderCode.exec(
            address(pay),
            abi.encodeCall(
                MihenkPay.createCampaign,
                (
                    kol,
                    address(token),
                    amount,
                    deliveryBps,
                    minLive,
                    uint40(block.timestamp + 1 days),
                    uint40(block.timestamp + 7 days + minLive),
                    termsHash
                )
            )
        );
        uint256 id = abi.decode(ret, (uint256));
        vm.stopBroadcast();
        console2.log("Campaign id:", id);

        vm.startBroadcast(kolKey);
        BuilderCode.exec(address(pay), abi.encodeCall(MihenkPay.acceptCampaign, (id)));
        vm.stopBroadcast();

        vm.startBroadcast(verifierKey);
        BuilderCode.exec(address(pay), abi.encodeCall(MihenkPay.settle, (id, delivered, reachHit, resultHash)));
        vm.stopBroadcast();
        console2.log("Settled. Run Finalize after the dispute window ends.");
    }
}
