// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";
import {MultisigKeyCutover} from "../script/MultisigKeyCutover.s.sol";
import {AcceptMultisigOwnership} from "../script/AcceptMultisigOwnership.s.sol";
import {VerifyProtocolKeyState} from "../script/VerifyProtocolKeyState.s.sol";

/// @notice Runs the key cutover scripts against a locally deployed protocol (Cyfrin bytestrike part 2).
/// @dev Scripts broadcast from DEFAULT_SENDER in tests, so it plays the deployer EOA. Everything runs in a
///      single test because the scripts read process-wide environment variables.
contract AuditFixesPart2KeyCutoverTest is BaseTest {
    CuOracle internal cuOracle;
    Oracle internal collateralOracle;

    address internal mainMs;
    address internal oracleMs;

    function setUp() public override {
        super.setUp();
        mainMs = makeAddr("mainMultisig");
        oracleMs = makeAddr("oracleMultisig");
        vm.startPrank(admin);
        cuOracle = new CuOracle(admin, 1);
        collateralOracle = new Oracle();
        vm.stopPrank();
    }

    /// @dev Hands every admin power held by `from` to `to`; `accept` completes Ownable2Step transfers.
    function _handOver(address from, address to, bool accept) internal {
        vm.startPrank(from);
        clearingHouse.transferOwnership(to);
        vamm.transferOwnership(to);
        feeRouter.transferOwnership(to);
        insuranceFund.transferOwnership(to);
        cuOracle.transferOwnership(to);
        collateralOracle.transferOwnership(to);
        bytes32[4] memory regRoles = [
            marketRegistry.DEFAULT_ADMIN_ROLE(),
            marketRegistry.MARKET_ADMIN_ROLE(),
            marketRegistry.PARAM_ADMIN_ROLE(),
            marketRegistry.PAUSE_GUARDIAN_ROLE()
        ];
        for (uint256 i; i < 4; i++) marketRegistry.grantRole(regRoles[i], to);
        for (uint256 i; i < 4; i++) marketRegistry.renounceRole(regRoles[i], from);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), to);
        vault.grantRole(vault.VAULT_ADMIN_ROLE(), to);
        vault.renounceRole(vault.VAULT_ADMIN_ROLE(), from);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), from);
        vm.stopPrank();
        if (accept) _acceptAll(to, to);
    }

    function _acceptAll(address main, address oracleAdmin) internal {
        vm.startPrank(main);
        vamm.acceptOwnership();
        feeRouter.acceptOwnership();
        insuranceFund.acceptOwnership();
        vm.stopPrank();
        vm.startPrank(oracleAdmin);
        cuOracle.acceptOwnership();
        collateralOracle.acceptOwnership();
        vm.stopPrank();
    }

    function _setEnv(address main, address oracleAdmin, address oldAdmin) internal {
        vm.setEnv("MAIN_ADMIN_MULTISIG", vm.toString(main));
        vm.setEnv("ORACLE_ADMIN_MULTISIG", vm.toString(oracleAdmin));
        vm.setEnv("OLD_ADMIN", vm.toString(oldAdmin));
        vm.setEnv("OLD_ORACLE_PUBLISHER", vm.toString(oldAdmin));
        vm.setEnv("ORACLE_PUBLISHER", vm.toString(makeAddr("publisher")));
        vm.setEnv("TREASURY_MULTISIG", vm.toString(makeAddr("treasuryMultisig")));
        vm.setEnv("PAUSE_GUARDIAN_MULTISIG", vm.toString(makeAddr("pauseMultisig")));
        vm.setEnv("CLEARING_HOUSE", vm.toString(address(clearingHouse)));
        vm.setEnv("COLLATERAL_VAULT", vm.toString(address(vault)));
        vm.setEnv("MARKET_REGISTRY", vm.toString(address(marketRegistry)));
        vm.setEnv("FEE_ROUTER", vm.toString(address(feeRouter)));
        vm.setEnv("INSURANCE_FUND", vm.toString(address(insuranceFund)));
        vm.setEnv("CU_ORACLE", vm.toString(address(cuOracle)));
        vm.setEnv("COLLATERAL_ORACLE", vm.toString(address(collateralOracle)));
        vm.setEnv("MARKET_IDS", vm.toString(ETH_PERP));
    }

    /// @notice Finding 30: the cutover hands over the collateral Oracle by default and every vAMM
    /// resolved from MarketRegistry; acceptance and verification use the same market list and the
    /// verifier fails until the end state is complete.
    function test_Finding30_cutoverHandsOffEverythingAndVerifies() public {
        address deployer = DEFAULT_SENDER;
        _handOver(admin, deployer, true);
        _setEnv(mainMs, oracleMs, deployer);
        VerifyProtocolKeyState verifier = new VerifyProtocolKeyState();

        // Before the cutover the verifier fails.
        vm.expectRevert(bytes("vAMM not owned by main admin"));
        verifier.run();

        // Cutover: TRANSFER_COLLATERAL_ORACLE is not set, so the collateral Oracle moves by default.
        MultisigKeyCutover cutover = new MultisigKeyCutover();
        cutover.run();
        assertEq(clearingHouse.owner(), mainMs, "CH owner");
        assertEq(vamm.pendingOwner(), mainMs, "vAMM from MarketRegistry not handed off");
        assertEq(feeRouter.pendingOwner(), mainMs, "FeeRouter");
        assertEq(insuranceFund.pendingOwner(), mainMs, "InsuranceFund");
        assertEq(cuOracle.pendingOwner(), oracleMs, "CuOracle");
        assertEq(collateralOracle.pendingOwner(), oracleMs, "collateral Oracle not handed off by default");
        assertFalse(marketRegistry.hasRole(marketRegistry.DEFAULT_ADMIN_ROLE(), deployer), "registry admin kept");
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer), "vault admin kept");

        // Pending transfers are not a finished cutover.
        vm.expectRevert(bytes("vAMM not owned by main admin"));
        verifier.run();

        _acceptAll(mainMs, oracleMs);
        verifier.run();

        // An unknown market id fails instead of being skipped.
        vm.setEnv("MARKET_IDS", vm.toString(keccak256("UNKNOWN")));
        vm.expectRevert(bytes("MARKET_IDS: unknown market"));
        cutover.marketVamms(address(marketRegistry));
        vm.setEnv("MARKET_IDS", vm.toString(ETH_PERP));

        // Acceptance script: multisigs hand pending ownership to the script signer, which accepts the
        // vAMM resolved from MarketRegistry and, by default, the collateral Oracle.
        vm.startPrank(mainMs);
        vamm.transferOwnership(deployer);
        feeRouter.transferOwnership(deployer);
        insuranceFund.transferOwnership(deployer);
        vm.stopPrank();
        vm.startPrank(oracleMs);
        cuOracle.transferOwnership(deployer);
        collateralOracle.transferOwnership(deployer);
        vm.stopPrank();
        vm.setEnv("MAIN_ADMIN_MULTISIG", vm.toString(deployer));
        vm.setEnv("ORACLE_ADMIN_MULTISIG", vm.toString(deployer));

        new AcceptMultisigOwnership().run();
        assertEq(vamm.owner(), deployer, "vAMM not accepted");
        assertEq(feeRouter.owner(), deployer, "FeeRouter not accepted");
        assertEq(insuranceFund.owner(), deployer, "InsuranceFund not accepted");
        assertEq(cuOracle.owner(), deployer, "CuOracle not accepted");
        assertEq(collateralOracle.owner(), deployer, "collateral Oracle not accepted by default");
    }
}
