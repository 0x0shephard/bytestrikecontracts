// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BCScript } from "battlechain-lib/BCScript.sol";
import { Contact, AgreementDetails } from "battlechain-lib/types/AgreementTypes.sol";
import { console } from "forge-std/console.sol";

interface IMockRegistryModerator {
    function approveAttack(address agreementAddress) external;
}

interface IAttackRegistryExt {
    function requestUnderAttackByNonAuthorized(address agreementAddress) external;
}

/// @title FixSafeHarborAndAttackMode
/// @notice Creates a v3 Safe Harbor agreement on the new registry/factory,
///         requests attack mode via the non-authorized path, and self-approves
///         via the testnet MockRegistryModerator.
///
/// New BC infrastructure (March 2026):
///   AttackRegistry:        0xdD029a6374095EEb4c47a2364Ce1D0f47f007350
///   SafeHarborRegistry:    0x0a652e265336a0296816aC4D8400880e3E537C24
///   AgreementFactory:      0x2Bee2970f10FDc2aeA28662BB6F6A501278Ebd46
///   MockRegistryModerator: 0x1bC64E6F187a47D136106784f4E9182801535BD3
///
/// Run:
///   forge script script/FixSafeHarborAndAttackMode.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
contract FixSafeHarborAndAttackMode is BCScript {

    address constant MOCK_MODERATOR = 0x1bC64E6F187a47D136106784f4E9182801535BD3;
    
        uint256 constant BATTLECHAIN_TESTNET_CHAIN_ID = 627;
    
        address constant EXPECTED_ATTACK_REGISTRY = 0xdD029a6374095EEb4c47a2364Ce1D0f47f007350;
        address constant EXPECTED_SAFE_HARBOR_REGISTRY = 0x0a652e265336a0296816aC4D8400880e3E537C24;
        address constant EXPECTED_AGREEMENT_FACTORY = 0x2Bee2970f10FDc2aeA28662BB6F6A501278Ebd46;
    
        error WrongChain(uint256 actualChainId);
        error UnexpectedAttackRegistry(address actual);
        error UnexpectedSafeHarborRegistry(address actual);
        error UnexpectedAgreementFactory(address actual);

    function _protocolName() internal pure override returns (string memory) {
        return "ByteStrike";
    }

    function _contacts() internal pure override returns (Contact[] memory) {
        Contact[] memory contacts = new Contact[](1);
        contacts[0] = Contact({ name: "ByteStrike Security", contact: "security@bytestrike.io" });
        return contacts;
    }

    function _recoveryAddress() internal view override returns (address) {
        return msg.sender;
    }

    function _assertBattleChainEndpoints() internal view {
        if (block.chainid != BATTLECHAIN_TESTNET_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        address attackRegistry = _bcAttackRegistry();
        if (attackRegistry != EXPECTED_ATTACK_REGISTRY) {
            revert UnexpectedAttackRegistry(attackRegistry);
        }

        address safeHarborRegistry = _bcRegistry();
        if (safeHarborRegistry != EXPECTED_SAFE_HARBOR_REGISTRY) {
            revert UnexpectedSafeHarborRegistry(safeHarborRegistry);
        }

        address agreementFactory = _bcFactory();
        if (agreementFactory != EXPECTED_AGREEMENT_FACTORY) {
            revert UnexpectedAgreementFactory(agreementFactory);
        }
    }

    function run() external {
        _assertBattleChainEndpoints();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address[] memory contracts = new address[](13);
        contracts[0]  = 0x2E3f3D9aC763C3c7D8F5A9D6A94dD745D76D9e8f; // CuOracle
        contracts[1]  = 0x3C1085dF918a38A95F84945E6705CC857b664074; // CuOracleAdapter (CU-PERP)
        contracts[2]  = 0x4719869E2EceaADa61536906eeE68d483C6acABc; // CuOracleAdapter (H100-PERP)
        contracts[3]  = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F; // MarketRegistry
        contracts[4]  = 0x5eb81A19Bc42CA3Fb034C5250EbFC00E4D0F3a7e; // CollateralVault
        contracts[5]  = 0x79299Dc44AFEC5e816d7EFD89f698Eca8Efb305c; // ClearingHouse (proxy)
        contracts[6]  = 0xE25dE08316Fe45C2235f17Af27f0449774d1c8Bd; // ClearingHouse (impl)
        contracts[7]  = 0x4Ed8079654eBA6a31c02B1d2Ed631bA215eC7B4a; // ClearingHouseLogic
        contracts[8]  = 0x6c9e72A4aFAc084d733B2D0d70d7ef3EB6E5450e; // vAMM (impl)
        contracts[9]  = 0xE56190a8a3a3a33e4C49418649a48d8174a82aE4; // vAMM proxy (H100-PERP-LIVE)
        contracts[10] = 0x5BfEC48dBf17690d429E04324Fe16c3e060b9A0a; // InsuranceFund (H100-PERP-LIVE)
        contracts[11] = 0x5AE261f4B595419bc5EDD82AAefa6b6000E49662; // FeeRouter (H100-PERP-LIVE)
        contracts[12] = 0xebE1D241b937e9D816aaA3a1816fA0D198d626ab; // VaultOracle (MockOracle)

        AgreementDetails memory details = defaultAgreementDetails(
            _protocolName(),
            _contacts(),
            contracts,
            _recoveryAddress()
        );

        vm.startBroadcast(deployerPrivateKey);

        // 1. Create + adopt agreement on new registry
        address agreement = createAndAdoptAgreement(
            details,
            deployer,
            keccak256("bytestrike-v4")
        );
        console.log("Safe Harbor v3 agreement:", agreement);

        // 2. Request attack mode (non-authorized path — no BattleChainDeployer)
        IAttackRegistryExt(_bcAttackRegistry()).requestUnderAttackByNonAuthorized(agreement);
        console.log("Attack mode requested");

        // 3. Self-approve via testnet MockRegistryModerator
        IMockRegistryModerator(MOCK_MODERATOR).approveAttack(agreement);
        console.log("Attack mode approved");

        vm.stopBroadcast();

        console.log("\n=== ByteStrike v3 Safe Harbor + Attack Mode ===");
        console.log("Agreement:       ", agreement);
        console.log("AttackRegistry:  ", _bcAttackRegistry());
        console.log("SHRegistry:      ", _bcRegistry());
        console.log("Scope:           13 contracts");
        console.log("Status:          UNDER ATTACK");
    }
}
