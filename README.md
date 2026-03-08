# ERC-3643 房产资产通证化平台

基于 Foundry 框架实现的参考 ERC-3643 设计思想的房产资产通证化解决方案。

## 项目概述

本项目实现了一个完整的合规证券代币系统,用于房产资产的通证化。核心特性包括:

- **链上身份验证 (ONCHAINID)**: 基于 ERC-734/735 标准的 KYC/AML 验证
- **模块化合规引擎**: 可插拔的合规规则系统
- **类 ERC-3643 证券代币能力**: 内置合规检查、身份验证与可升级治理
- **UUPS 可升级**: 支持合约升级以适应监管变化
- **投资者管理**: 自动跟踪投资者数量和持币情况

## 已实现的合约

### 1. 身份系统 (src/identity/)
- **Identity.sol** - 投资者身份合约 (基于 ERC-734/735)
- **ClaimIssuer.sol** - KYC/AML 声明签发者
- **IdentityRegistryStorage.sol** - 身份数据存储层
- **IdentityRegistry.sol** - 身份注册表与验证协调器

### 2. 合规系统 (src/compliance/)
- **ComplianceModule.sol** - 合规模块抽象基类
- **ModularCompliance.sol** - 模块化合规协调器
- **CountryRestrictModule.sol** - 国家/地区限制模块
- **TransferRestrictModule.sol** - 转账限制模块
- **InvestorLimitsModule.sol** - 投资者数量与持仓限制模块

### 3. 代币系统 (src/token/)
- **RealEstateToken.sol** - 证券代币核心合约 (ERC20 + 合规校验 + 强制转移/地址恢复)

### 4. 治理系统 (src/governance/)
- **TokenGovernance.sol** - 多签治理合约 (3/5 多签机制)

### 5. 分红系统 (src/distribution/)
- **RealEstateDividendDistributor.sol** - 房产收益分红分配器
- **MerkleTreeDividendDistributor.sol** - 基于 Merkle Tree 的分红分配器

## 快速开始

\`\`\`bash
# 编译
forge build

# 测试
forge test --offline -vv

# 部署
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
\`\`\`

`DeployFull.s.sol` 需要显式提供 `GOVERNANCE_OWNER_2` 与 `GOVERNANCE_OWNER_3` 环境变量。

