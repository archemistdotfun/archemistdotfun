// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { PairConfig } from "../ArchemistV4Types.sol";

interface IArchemistPairRegistry {
    function getPair(address quote) external view returns (PairConfig memory config);
}
