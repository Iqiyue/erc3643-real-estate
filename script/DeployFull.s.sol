// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Script.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/identity/Identity.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/identity/ClaimIssuer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/identity/IdentityRegistryStorage.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/identity/IdentityRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/compliance/ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/compliance/CountryRestrictModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/compliance/InvestorLimitsModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/compliance/TransferRestrictModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/token/RealEstateToken.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/distribution/MerkleTreeDividendDistributor.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/governance/TokenGovernance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployFullSystem is Script {
    struct Deployment {
        ClaimIssuer claimIssuer;
        IdentityRegistryStorage identityStorage;
        IdentityRegistry identityRegistry;
        CountryRestrictModule countryModule;
        InvestorLimitsModule investorLimitsModule;
        TransferRestrictModule transferRestrictModule;
        ModularCompliance compliance;
        RealEstateToken tokenImplementation;
        ERC1967Proxy tokenProxy;
        MerkleTreeDividendDistributor dividendDistributor;
        TokenGovernance governance;
    }

    Deployment internal d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying ERC-3643 Real Estate Platform ===");
        console.log("Deployer:", deployer);

        _deployIdentity();
        _deployCompliance();
        _deployToken();
        _deployDistribution();
        _deployGovernance(deployer);

        // ========== 配置权限 ==========
        console.log("\n[*] Configuring Permissions...");

        RealEstateToken token = RealEstateToken(address(d.tokenProxy));
        token.transferOwnership(address(d.governance));
        d.compliance.transferOwnership(address(d.governance));
        d.dividendDistributor.transferOwnership(address(d.governance));
        console.log("  Ownership transferred to Governance");

        vm.stopBroadcast();

        // ========== 部署总结 ==========
        _printSummary();
    }

    function _deployIdentity() internal {
        console.log("\n[1/6] Deploying Identity Infrastructure...");

        d.claimIssuer = new ClaimIssuer();
        d.identityStorage = new IdentityRegistryStorage();

        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(d.claimIssuer);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1;

        d.identityRegistry = new IdentityRegistry(
            address(d.identityStorage),
            trustedIssuers,
            claimTopics
        );

        d.identityStorage.bindIdentityRegistry(address(d.identityRegistry));
        console.log("  ClaimIssuer:", address(d.claimIssuer));
        console.log("  IdentityRegistryStorage:", address(d.identityStorage));
        console.log("  IdentityRegistry:", address(d.identityRegistry));
    }

    function _deployCompliance() internal {
        console.log("\n[2/6] Deploying Compliance Modules...");

        d.countryModule = new CountryRestrictModule(true);
        d.countryModule.addCountryToWhitelist(840);
        d.countryModule.addCountryToWhitelist(156);
        d.countryModule.addCountryToWhitelist(826);

        d.investorLimitsModule = new InvestorLimitsModule(2000, 2000, 1000 ether);
        d.transferRestrictModule = new TransferRestrictModule(365 days);
        console.log("  CountryRestrictModule:", address(d.countryModule));
        console.log("  InvestorLimitsModule:", address(d.investorLimitsModule));
        console.log("  TransferRestrictModule:", address(d.transferRestrictModule));

        console.log("\n[3/6] Deploying Compliance Engine...");
        d.compliance = new ModularCompliance();
        d.compliance.addModule(address(d.countryModule));
        d.compliance.addModule(address(d.investorLimitsModule));
        d.compliance.addModule(address(d.transferRestrictModule));
        console.log("  ModularCompliance:", address(d.compliance));
    }

    function _deployToken() internal {
        console.log("\n[4/6] Deploying Security Token...");

        d.tokenImplementation = new RealEstateToken();
        bytes memory initData = abi.encodeWithSelector(
            RealEstateToken.initialize.selector,
            "Real Estate Token",
            "RET",
            address(d.identityRegistry),
            address(d.compliance)
        );

        d.tokenProxy = new ERC1967Proxy(address(d.tokenImplementation), initData);
        d.compliance.bindToken(address(d.tokenProxy));
        console.log("  RealEstateToken (Implementation):", address(d.tokenImplementation));
        console.log("  RealEstateToken (Proxy):", address(d.tokenProxy));
    }

    function _deployDistribution() internal {
        console.log("\n[5/6] Deploying Dividend Distributor...");
        d.dividendDistributor = new MerkleTreeDividendDistributor();
        console.log("  MerkleTreeDividendDistributor:", address(d.dividendDistributor));
    }

    function _deployGovernance(address deployer) internal {
        console.log("\n[6/6] Deploying Governance...");

        address owner2 = vm.envAddress("GOVERNANCE_OWNER_2");
        address owner3 = vm.envAddress("GOVERNANCE_OWNER_3");
        require(owner2 != deployer && owner3 != deployer && owner2 != owner3, "Governance owners must be unique");

        address[] memory governanceOwners = new address[](3);
        governanceOwners[0] = deployer;
        governanceOwners[1] = owner2;
        governanceOwners[2] = owner3;

        d.governance = new TokenGovernance(governanceOwners, 2);
        address[] memory bootstrapTargets = new address[](8);
        bytes4[] memory bootstrapSelectors = new bytes4[](8);

        for (uint256 i = 0; i < 8; i++) {
            bootstrapTargets[i] = address(d.governance);
        }

        bootstrapSelectors[0] = TokenGovernance.addOwner.selector;
        bootstrapSelectors[1] = TokenGovernance.removeOwner.selector;
        bootstrapSelectors[2] = TokenGovernance.changeRequirement.selector;
        bootstrapSelectors[3] = TokenGovernance.allowTarget.selector;
        bootstrapSelectors[4] = TokenGovernance.disallowTarget.selector;
        bootstrapSelectors[5] = TokenGovernance.allowFunction.selector;
        bootstrapSelectors[6] = TokenGovernance.disallowFunction.selector;
        bootstrapSelectors[7] = TokenGovernance.batchAllowFunctions.selector;

        d.governance.bootstrapWhitelist(bootstrapTargets, bootstrapSelectors);
        console.log("  TokenGovernance:", address(d.governance));
    }

    function _printSummary() internal view {
        console.log("\n=== Deployment Summary ===");
        console.log("\n[Identity System]");
        console.log("ClaimIssuer:              ", address(d.claimIssuer));
        console.log("IdentityRegistryStorage:  ", address(d.identityStorage));
        console.log("IdentityRegistry:         ", address(d.identityRegistry));

        console.log("\n[Compliance Modules]");
        console.log("CountryRestrictModule:    ", address(d.countryModule));
        console.log("InvestorLimitsModule:     ", address(d.investorLimitsModule));
        console.log("TransferRestrictModule:   ", address(d.transferRestrictModule));
        console.log("ModularCompliance:        ", address(d.compliance));

        console.log("\n[Token System]");
        console.log("RealEstateToken (Proxy):  ", address(d.tokenProxy));
        console.log("RealEstateToken (Impl):   ", address(d.tokenImplementation));

        console.log("\n[Distribution & Governance]");
        console.log("DividendDistributor:      ", address(d.dividendDistributor));
        console.log("TokenGovernance:          ", address(d.governance));

        console.log("\n=== Configuration ===");
        console.log("Allowed Countries: USA(840), China(156), UK(826)");
        console.log("Max Investors: 2000");
        console.log("Max Holding: 20%");
        console.log("Min Investment: 1000 tokens");
        console.log("Lockup Period: 365 days");
        console.log("Governance: 2/3 multisig");
    }
}
