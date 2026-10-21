// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {TestUSD} from "../src/TestUSD.sol";

/// Env: DEPLOYER_KEY, VERIFIER, FEE_RECIPIENT, FEE_BPS (default 300),
///      TOKEN (optional; if empty a TestUSD is deployed),
///      DISPUTE_WINDOW (optional, seconds; default 3 days, minimum 24 hours),
///      OWNER (optional, e.g. a Safe multisig: ownership is offered to it with Ownable2Step and it
///      must call acceptOwnership(); until then the deployer stays owner).
/// Use separate keys for the owner, the verifier and the fee recipient.
contract Deploy is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(key);
        address verifier = vm.envOr("VERIFIER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(300)));
        address token = vm.envOr("TOKEN", address(0));
        uint40 window = uint40(vm.envOr("DISPUTE_WINDOW", uint256(3 days)));
        address finalOwner = vm.envOr("OWNER", deployer);

        vm.startBroadcast(key);
        if (token == address(0)) {
            TestUSD t = new TestUSD();
            t.mint(deployer, 10_000e6);
            token = address(t);
            console2.log("TestUSD:", token);
        }
        MihenkPay pay = new MihenkPay(deployer, verifier, feeRecipient, feeBps);
        pay.setTokenAllowed(token, true);
        if (window != pay.disputeWindow()) pay.setDisputeWindow(window);
        if (finalOwner != deployer) pay.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console2.log("MihenkPay:", address(pay));
        console2.log("Token allowed:", token);
        console2.log("Verifier:", verifier);
        console2.log("Fee recipient:", feeRecipient);
        if (finalOwner != deployer) console2.log("Pending owner (must accept):", finalOwner);
    }
}
