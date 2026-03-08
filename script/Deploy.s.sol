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
import "../src/token/RealEstateToken.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 ClaimIssuer (KYC 提供商)
        ClaimIssuer claimIssuer = new ClaimIssuer();
        console.log("ClaimIssuer deployed at:", address(claimIssuer));

        // 2. 部署 IdentityRegistryStorage
        IdentityRegistryStorage identityStorage = new IdentityRegistryStorage();
        console.log("IdentityRegistryStorage deployed at:", address(identityStorage));

        // 3. 部署 IdentityRegistry
        address[] memory trustedIssuers = new address[](1);
        trustedIssuers[0] = address(claimIssuer);

        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = 1; // KYC 验证

        IdentityRegistry identityRegistry = new IdentityRegistry(
            address(identityStorage),
            trustedIssuers,
            claimTopics
        );
        console.log("IdentityRegistry deployed at:", address(identityRegistry));

        // 绑定 IdentityRegistry 到 Storage
        identityStorage.bindIdentityRegistry(address(identityRegistry));

        // 4. 部署 ModularCompliance
        ModularCompliance compliance = new ModularCompliance();
        console.log("ModularCompliance deployed at:", address(compliance));

        // 5. 部署 RealEstateToken (UUPS 代理模式)
        RealEstateToken tokenImplementation = new RealEstateToken();
        console.log("RealEstateToken implementation deployed at:", address(tokenImplementation));

        bytes memory initData = abi.encodeWithSelector(
            RealEstateToken.initialize.selector,
            "Real Estate Token",
            "RET",
            address(identityRegistry),
            address(compliance)
        );

        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImplementation), initData);
        console.log("RealEstateToken proxy deployed at:", address(tokenProxy));

        // 绑定代币到合规引擎
        compliance.bindToken(address(tokenProxy));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ClaimIssuer:", address(claimIssuer));
        console.log("IdentityRegistryStorage:", address(identityStorage));
        console.log("IdentityRegistry:", address(identityRegistry));
        console.log("ModularCompliance:", address(compliance));
        console.log("RealEstateToken (Proxy):", address(tokenProxy));
    }
}
