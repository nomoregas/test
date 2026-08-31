// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract Slots {
    uint256 public a = 1;
    uint256 public b = 1;

    function bump() external {
        a += 1;
        b += 1;
    }
}

/// @notice Establishes what `vm.cool` actually resets, so the benchmarks quote a real baseline.
/// @dev A cold `SLOAD` is 2100 and a warm one 100 (EIP-2929), so two cold slot accesses plus their
///      non-zero stores should land near 10,000 and the warm version near 6,000. If both readings
///      come out the same, `vm.cool` is not resetting slots and every figure measured with it is a
///      warm-storage number wearing a cold label.
contract CoolProbe is Test {
    Slots s;

    function setUp() public {
        s = new Slots();
        s.bump(); // make both slots non-zero and warm
    }

    function test_whatCoolResets() public {
        // Warm: no cool call.
        uint256 before = gasleft();
        s.bump();
        uint256 warm = before - gasleft();

        // After vm.cool.
        vm.cool(address(s));
        before = gasleft();
        s.bump();
        uint256 cooled = before - gasleft();

        // After explicitly cooling each slot.
        vm.coolSlot(address(s), bytes32(uint256(0)));
        vm.coolSlot(address(s), bytes32(uint256(1)));
        before = gasleft();
        s.bump();
        uint256 slotCooled = before - gasleft();

        console.log("warm            :", warm);
        console.log("after vm.cool   :", cooled);
        console.log("after coolSlot x2:", slotCooled);
        console.log("cold surcharge from cool    :", cooled > warm ? cooled - warm : 0);
        console.log("cold surcharge from coolSlot:", slotCooled > warm ? slotCooled - warm : 0);
    }
}
