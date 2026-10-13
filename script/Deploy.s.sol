// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {TestUSD} from "../src/TestUSD.sol";

/// Env: DEPLOYER_KEY, VERIFIER, FEE_RECIPIENT, FEE_BPS (default 300),
///      TOKEN (optional; if empty a TestUSD is deployed), DISPUTE_WINDOW (optional, seconds)
contract Deploy is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(key);
        address verifier = vm.envOr("VERIFIER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(300)));
        address token = vm.envOr("TOKEN", address(0));
        uint40 window = uint40(vm.envOr("DISPUTE_WINDOW", uint256(1 hours)));

        vm.startBroadcast(key);
        if (token == address(0)) {
            TestUSD t = new TestUSD();
            t.mint(deployer, 10_000e6);
            token = address(t);
            console2.log("TestUSD:", token);
        }
        MihenkPay pay = new MihenkPay(deployer, verifier, feeRecipient, feeBps);
        pay.setTokenAllowed(token, true);
        pay.setDisputeWindow(window);
        vm.stopBroadcast();

        console2.log("MihenkPay:", address(pay));
        console2.log("Token allowed:", token);
        console2.log("Verifier:", verifier);
    }
}
