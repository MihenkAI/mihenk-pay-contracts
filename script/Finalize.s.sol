// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {BuilderCode} from "./BuilderCode.sol";

/// Env: PAY_CONTRACT, CAMPAIGN_ID, CALLER_KEY (anyone can finalize)
/// On Base mainnet the transaction carries Mihenk AI's Builder Code (see BuilderCode.sol).
contract Finalize is Script {
    function run() external {
        MihenkPay pay = MihenkPay(vm.envAddress("PAY_CONTRACT"));
        uint256 id = vm.envUint("CAMPAIGN_ID");
        vm.startBroadcast(vm.envUint("CALLER_KEY"));
        BuilderCode.exec(address(pay), abi.encodeCall(MihenkPay.finalize, (id)));
        vm.stopBroadcast();
        console2.log("Finalized campaign:", id);
    }
}
