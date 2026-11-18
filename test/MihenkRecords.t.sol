// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MihenkRecords} from "../src/MihenkRecords.sol";

contract MihenkRecordsTest is Test {
    MihenkRecords internal r;
    bytes32 internal constant KIND = "0G_STORAGE_DAILY";

    event Recorded(bytes32 indexed kind, uint32 indexed day, bytes32 root, string uri);

    function setUp() public {
        r = new MihenkRecords();
    }

    function testWriterIsDeployer() public view {
        assertEq(r.writer(), address(this));
    }

    function testRecord() public {
        vm.expectEmit(true, true, false, true);
        emit Recorded(KIND, 20261117, bytes32(uint256(1)), "https://app.mihenkai.com/x402/0g?day=2026-11-17");
        r.record(KIND, 20261117, bytes32(uint256(1)), "https://app.mihenkai.com/x402/0g?day=2026-11-17");
        assertEq(r.rootOf(KIND, 20261117), bytes32(uint256(1)));
        assertEq(r.count(), 1);
    }

    function testOnlyWriter() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(MihenkRecords.NotWriter.selector);
        r.record(KIND, 20261117, bytes32(uint256(1)), "");
    }

    function testNoOverwrite() public {
        r.record(KIND, 20261117, bytes32(uint256(1)), "");
        vm.expectRevert(
            abi.encodeWithSelector(MihenkRecords.AlreadyRecorded.selector, KIND, uint32(20261117), bytes32(uint256(1)))
        );
        r.record(KIND, 20261117, bytes32(uint256(2)), "");
        assertEq(r.rootOf(KIND, 20261117), bytes32(uint256(1)));
        assertEq(r.count(), 1);
    }

    function testEmptyRoot() public {
        vm.expectRevert(MihenkRecords.EmptyRoot.selector);
        r.record(KIND, 20261117, bytes32(0), "");
    }

    function testKindsAreSeparate() public {
        r.record(KIND, 20261117, bytes32(uint256(1)), "");
        r.record("EVIDENCE_SEAL", 20261117, bytes32(uint256(2)), "");
        assertEq(r.rootOf(KIND, 20261117), bytes32(uint256(1)));
        assertEq(r.rootOf("EVIDENCE_SEAL", 20261117), bytes32(uint256(2)));
        assertEq(r.count(), 2);
    }

    function testFuzzRecordOnce(bytes32 kind, uint32 day, bytes32 root, bytes32 root2) public {
        vm.assume(root != bytes32(0) && root2 != bytes32(0));
        r.record(kind, day, root, "");
        assertEq(r.rootOf(kind, day), root);
        vm.expectRevert(abi.encodeWithSelector(MihenkRecords.AlreadyRecorded.selector, kind, day, root));
        r.record(kind, day, root2, "");
    }
}
