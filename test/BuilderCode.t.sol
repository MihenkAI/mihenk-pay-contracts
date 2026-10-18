// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MihenkPay} from "../src/MihenkPay.sol";
import {BuilderCode} from "../script/BuilderCode.sol";
import {MockUSD} from "./MihenkPay.t.sol";

/// Builder Code suffix: correct ERC-8021 layout, only on Base mainnet, and MihenkPay works with it.
contract BuilderCodeTest is Test {
    MihenkPay pay;
    MockUSD usd;
    address owner = makeAddr("owner");
    address verifier = makeAddr("verifier");
    address treasury = makeAddr("treasury");
    address sponsor = makeAddr("sponsor");
    address kol = makeAddr("kol");

    function setUp() public {
        vm.chainId(8453);
        pay = new MihenkPay(owner, verifier, treasury, 300);
        usd = new MockUSD();
        vm.prank(owner);
        pay.setTokenAllowed(address(usd), true);
        usd.mint(sponsor, 10e6);
    }

    function test_suffixLayout() public pure {
        bytes memory s = BuilderCode.SUFFIX;
        assertEq(s.length, 11 + 1 + 1 + 16);
        bytes memory code = new bytes(11);
        for (uint256 i; i < 11; i++) code[i] = s[i];
        assertEq(string(code), "bc_s415ugdv");
        assertEq(uint8(s[11]), 11); // code length
        assertEq(uint8(s[12]), 0); // schema 0
        for (uint256 i; i < 8; i++) {
            assertEq(uint8(s[13 + 2 * i]), 0x80);
            assertEq(uint8(s[14 + 2 * i]), 0x21);
        }
    }

    function test_tagOnlyOnBaseMainnet() public {
        bytes memory d = hex"deadbeef";
        vm.chainId(1);
        assertEq(BuilderCode.tag(d), d);
        vm.chainId(8453);
        assertEq(BuilderCode.tag(d), bytes.concat(d, BuilderCode.SUFFIX));
    }

    function _call(address from, address target, bytes memory data) internal returns (bytes memory ret) {
        bytes memory tagged = BuilderCode.tag(data);
        assertEq(tagged.length, data.length + BuilderCode.SUFFIX.length);
        vm.prank(from);
        bool ok;
        (ok, ret) = target.call(tagged);
        assertTrue(ok, "call with builder code suffix reverted");
    }

    function test_campaignLifecycleWithSuffix() public {
        _call(sponsor, address(usd), abi.encodeCall(usd.approve, (address(pay), 2e6)));
        bytes memory ret = _call(
            sponsor,
            address(pay),
            abi.encodeCall(
                MihenkPay.createCampaign,
                (
                    kol,
                    address(usd),
                    uint128(2e6),
                    uint16(5000),
                    uint40(block.timestamp + 1 days),
                    uint40(block.timestamp + 7 days),
                    keccak256("terms")
                )
            )
        );
        uint256 id = abi.decode(ret, (uint256));
        _call(kol, address(pay), abi.encodeCall(MihenkPay.acceptCampaign, (id)));
        _call(verifier, address(pay), abi.encodeCall(MihenkPay.settle, (id, true, true, keccak256("report"))));
        vm.warp(block.timestamp + pay.disputeWindow() + 1);
        _call(sponsor, address(pay), abi.encodeCall(MihenkPay.finalize, (id)));
        assertEq(usd.balanceOf(kol), 1_940_000); // 2 USDC minus 3% fee
        assertEq(usd.balanceOf(treasury), 60_000);
        assertEq(usd.balanceOf(address(pay)), 0);
    }
}
