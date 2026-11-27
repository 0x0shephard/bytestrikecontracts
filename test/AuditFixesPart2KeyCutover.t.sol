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

    uint256 internal _now;

    function _warpPastAdminDelay() internal {
        if (_now == 0) _now = block.timestamp;
        _now += marketRegistry.INITIAL_DEFAULT_ADMIN_DELAY() + 1;
        vm.warp(_now);
    }

    /// @dev Hands every admin power held by `from` to `to` and lets `to` accept it all: Ownable2Step
    ///      transfers, the registry/vault default admin (two-step, after its delay), and the other
    ///      registry/vault roles, `from`'s being revoked by `to`.
    function _handOver(address from, address to) internal {
        vm.startPrank(from);
        clearingHouse.transferOwnership(to);
        vamm.transferOwnership(to);
        feeRouter.transferOwnership(to);
        insuranceFund.transferOwnership(to);
        cuOracle.transferOwnership(to);
        collateralOracle.transferOwnership(to);
        marketRegistry.beginDefaultAdminTransfer(to);
        vault.beginDefaultAdminTransfer(to);
        bytes32[3] memory regRoles =
            [marketRegistry.MARKET_ADMIN_ROLE(), marketRegistry.PARAM_ADMIN_ROLE(), marketRegistry.PAUSE_GUARDIAN_ROLE()];
        for (uint256 i; i < 3; i++) marketRegistry.grantRole(regRoles[i], to);
        vault.grantRole(vault.VAULT_ADMIN_ROLE(), to);
        vm.stopPrank();

        _warpPastAdminDelay();
        _acceptAll(to, to);
        vm.startPrank(to);
        marketRegistry.acceptDefaultAdminTransfer();
        vault.acceptDefaultAdminTransfer();
        for (uint256 i; i < 3; i++) marketRegistry.revokeRole(regRoles[i], from);
        vault.revokeRole(vault.VAULT_ADMIN_ROLE(), from);
        vm.stopPrank();
    }

    function _acceptAll(address main, address oracleAdmin) internal {
        vm.startPrank(main);
        clearingHouse.acceptOwnership();
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

    /// @notice Findings 29 and 30: the cutover hands over the collateral Oracle by default and every vAMM
    /// resolved from MarketRegistry; nothing moves in one step (ClearingHouse is left pending, the
    /// registry/vault default admin transfer is only scheduled and the old admin keeps its roles), the
    /// main multisig accepts and revokes the old admin itself, and the verifier fails until then.
    function test_Finding30_cutoverHandsOffEverythingAndVerifies() public {
        address deployer = DEFAULT_SENDER;
        _handOver(admin, deployer);
        _setEnv(mainMs, oracleMs, deployer);
        VerifyProtocolKeyState verifier = new VerifyProtocolKeyState();

        // Before the cutover the verifier fails.
        vm.expectRevert(bytes("vAMM not owned by main admin"));
        verifier.run();

        // Cutover: TRANSFER_COLLATERAL_ORACLE is not set, so the collateral Oracle moves by default.
        MultisigKeyCutover cutover = new MultisigKeyCutover();
        cutover.run();
        assertEq(clearingHouse.owner(), deployer, "CH moved in one step");
        assertEq(clearingHouse.pendingOwner(), mainMs, "CH not pending to main admin");
        assertEq(vamm.pendingOwner(), mainMs, "vAMM from MarketRegistry not handed off");
        assertEq(feeRouter.pendingOwner(), mainMs, "FeeRouter");
        assertEq(insuranceFund.pendingOwner(), mainMs, "InsuranceFund");
        assertEq(cuOracle.pendingOwner(), oracleMs, "CuOracle");
        assertEq(collateralOracle.pendingOwner(), oracleMs, "collateral Oracle not handed off by default");
        (address pendingRegAdmin,) = marketRegistry.pendingDefaultAdmin();
        (address pendingVaultAdmin,) = vault.pendingDefaultAdmin();
        assertEq(pendingRegAdmin, mainMs, "registry default admin not scheduled");
        assertEq(pendingVaultAdmin, mainMs, "vault default admin not scheduled");
        assertTrue(marketRegistry.hasRole(marketRegistry.DEFAULT_ADMIN_ROLE(), deployer), "registry admin dropped early");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer), "vault admin dropped early");
        assertTrue(marketRegistry.hasRole(marketRegistry.MARKET_ADMIN_ROLE(), deployer), "old roles revoked by the cutover");

        // Pending transfers are not a finished cutover.
        vm.expectRevert(bytes("vAMM not owned by main admin"));
        verifier.run();

        // The multisigs accept; the main multisig revokes the deployer's remaining roles itself.
        _warpPastAdminDelay();
        _acceptAll(mainMs, oracleMs);
        vm.startPrank(mainMs);
        marketRegistry.acceptDefaultAdminTransfer();
        vault.acceptDefaultAdminTransfer();
        marketRegistry.revokeRole(marketRegistry.MARKET_ADMIN_ROLE(), deployer);
        marketRegistry.revokeRole(marketRegistry.PARAM_ADMIN_ROLE(), deployer);
        marketRegistry.revokeRole(marketRegistry.PAUSE_GUARDIAN_ROLE(), deployer);
        vault.revokeRole(vault.VAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();
        verifier.run();

        // An unknown market id fails instead of being skipped.
        vm.setEnv("MARKET_IDS", vm.toString(keccak256("UNKNOWN")));
        vm.expectRevert(bytes("MARKET_IDS: unknown market"));
        cutover.marketVamms(address(marketRegistry));
        vm.setEnv("MARKET_IDS", vm.toString(ETH_PERP));

        // Acceptance script: the multisigs hand everything to the script signer, which accepts
        // ClearingHouse, the vAMM resolved from MarketRegistry, the registry/vault default admin and,
        // by default, the collateral Oracle, then revokes OLD_ADMIN's registry/vault roles.
        vm.startPrank(mainMs);
        clearingHouse.transferOwnership(deployer);
        vamm.transferOwnership(deployer);
        feeRouter.transferOwnership(deployer);
        insuranceFund.transferOwnership(deployer);
        marketRegistry.beginDefaultAdminTransfer(deployer);
        vault.beginDefaultAdminTransfer(deployer);
        marketRegistry.grantRole(marketRegistry.MARKET_ADMIN_ROLE(), deployer);
        vault.grantRole(vault.VAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();
        vm.startPrank(oracleMs);
        cuOracle.transferOwnership(deployer);
        collateralOracle.transferOwnership(deployer);
        vm.stopPrank();
        vm.setEnv("MAIN_ADMIN_MULTISIG", vm.toString(deployer));
        vm.setEnv("ORACLE_ADMIN_MULTISIG", vm.toString(deployer));
        vm.setEnv("OLD_ADMIN", vm.toString(mainMs));
        _warpPastAdminDelay();

        new AcceptMultisigOwnership().run();
        assertEq(clearingHouse.owner(), deployer, "ClearingHouse not accepted");
        assertEq(vamm.owner(), deployer, "vAMM not accepted");
        assertEq(feeRouter.owner(), deployer, "FeeRouter not accepted");
        assertEq(insuranceFund.owner(), deployer, "InsuranceFund not accepted");
        assertEq(cuOracle.owner(), deployer, "CuOracle not accepted");
        assertEq(collateralOracle.owner(), deployer, "collateral Oracle not accepted by default");
        assertEq(marketRegistry.defaultAdmin(), deployer, "registry default admin not accepted");
        assertEq(vault.defaultAdmin(), deployer, "vault default admin not accepted");
        assertFalse(marketRegistry.hasRole(marketRegistry.MARKET_ADMIN_ROLE(), mainMs), "old market admin kept");
        assertFalse(vault.hasRole(vault.VAULT_ADMIN_ROLE(), mainMs), "old vault admin kept");
    }
}
