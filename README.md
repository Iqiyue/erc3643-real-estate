# 🏠 ERC-3643 房产资产通证化平台


基于 Foundry 框架实现的参考 ERC-3643 设计思想的房产资产通证化解决方案。

## ✨ 核心特性

- **🔐 链上身份验证 (ONCHAINID)**：基于 ERC-734/735 标准的 KYC/AML 验证系统
- **📋 模块化合规引擎**：可插拔的合规规则系统，支持国家限制、投资者数量限制、持仓限制
- **🪙 证券代币能力**：内置合规检查、身份验证、强制转移与地址恢复功能
- **🔄 UUPS 可升级**：支持合约升级以适应监管变化，带 7 天时间锁保护
- **👥 投资者管理**：自动跟踪投资者数量和持币情况
- **💰 分红系统**：支持 ETH 和 ERC20 代币分红，拉取式和推送式两种模式
- **🏛️ 多签治理**：3/5 多签提案机制，保护关键操作

## 🏗️ 项目架构

```
src/
├── identity/              # 身份验证系统
│   ├── Identity.sol       # 投资者身份合约 (ERC-734/735)
│   ├── ClaimIssuer.sol    # KYC/AML 声明签发者
│   ├── IdentityRegistryStorage.sol  # 身份数据存储
│   └── IdentityRegistry.sol         # 身份注册表
├── compliance/            # 合规引擎
│   ├── ComplianceModule.sol         # 合规模块基类
│   ├── ModularCompliance.sol        # 模块化合规协调器
│   ├── CountryRestrictModule.sol    # 国家/地区限制
│   ├── TransferRestrictModule.sol   # 转账限制
│   └── InvestorLimitsModule.sol     # 投资者数量与持仓限制
├── token/                 # 代币系统
│   └── RealEstateToken.sol          # 证券代币核心合约
├── governance/            # 治理系统
│   └── TokenGovernance.sol          # 多签治理合约
└── distribution/          # 分红系统
    ├── RealEstateDividendDistributor.sol  # 房产收益分红
    └── MerkleTreeDividendDistributor.sol  # Merkle Tree 分红

test/
├── unit/                  # 单元测试
├── fuzz/                  # Fuzz 测试
├── invariant/             # Invariant 测试
├── integration/           # 集成测试
├── security/              # 安全测试
└── upgrade/               # 升级测试
```

## 🛠️ 技术栈

- **Solidity**: 0.8.20
- **框架**: Foundry
- **标准**: ERC-20, ERC-734, ERC-735, ERC-1967 (UUPS)
- **库**: OpenZeppelin Contracts Upgradeable
- **测试**: Foundry Test (Unit + Fuzz + Invariant)

## 📊 测试覆盖

- ✅ **单元测试**: 8 个测试文件，覆盖所有核心功能
- ✅ **Fuzz 测试**: 测试边界情况和随机输入
- ✅ **Invariant 测试**: 验证核心不变量（总供应量、投资者数量等）
- ✅ **集成测试**: 测试模块间协作
- ✅ **安全测试**: 测试重入、权限、时间锁等安全机制
- ✅ **升级测试**: 测试 UUPS 升级流程

```bash
# 运行所有测试
forge test --offline -vv

# 查看测试覆盖率
forge coverage
```

## 🔒 安全特性

### 身份与合规
- ✅ KYC/AML 验证（基于 ERC-734/735）
- ✅ 模块化合规检查（国家限制、投资者数量、持仓限制）
- ✅ 身份过期检查
- ✅ 合规状态实时验证

### 访问控制
- ✅ 基于角色的权限管理（Owner、Agent、Guardian）
- ✅ 多签治理（3/5 多签提案机制）
- ✅ 时间锁保护（升级需要 7 天等待期）

### 安全机制
- ✅ 重入防护（ReentrancyGuard）
- ✅ 暂停机制（Pausable）
- ✅ 地址冻结功能
- ✅ 防抢跑攻击（Mint 间隔限制）
- ✅ 紧急暂停冷却期（24 小时）

### 升级安全
- ✅ UUPS 可升级模式
- ✅ 7 天升级时间锁
- ✅ 2 天取消冷却期
- ✅ 升级提案可撤销

## 🚀 快速开始

### 安装依赖

```bash
# 克隆项目
git clone https://github.com/Iqiyue/erc3643-real-estate.git
cd erc3643-real-estate

# 安装 Foundry（如果还没安装）
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 安装依赖
forge install
```

### 编译

```bash
forge build
```

### 测试

```bash
# 运行所有测试
forge test --offline -vv

# 运行特定测试
forge test --match-test testMint -vv

# 查看测试覆盖率
forge coverage

# 运行 Gas 报告
forge test --gas-report
```

### 部署

```bash
# 部署到本地网络
forge script script/Deploy.s.sol --rpc-url localhost --broadcast

# 部署到测试网（需要设置环境变量）
forge script script/DeployFull.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

**注意**: `DeployFull.s.sol` 需要设置以下环境变量：
- `GOVERNANCE_OWNER_2`: 第二个治理所有者地址
- `GOVERNANCE_OWNER_3`: 第三个治理所有者地址

## 📝 核心合约说明

### 1. Identity.sol - 身份合约
实现 ERC-734/735 标准的链上身份系统，支持：
- 添加/移除 KYC 声明
- 验证声明有效性
- 检查声明过期时间

### 2. ModularCompliance.sol - 合规引擎
模块化的合规检查系统，支持：
- 动态添加/移除合规模块
- 国家/地区限制
- 投资者数量限制（最多 2000 人）
- 单地址持仓限制（最多 20%）
- 锁定期限制（365 天）

### 3. RealEstateToken.sol - 证券代币
符合 ERC-20 标准的证券代币，额外功能：
- 转账前合规检查
- 强制转移（用于法律执行）
- 地址恢复（用于私钥丢失）
- 地址冻结功能
- UUPS 可升级

### 4. TokenGovernance.sol - 治理系统
3/5 多签治理合约，支持：
- 提案提交
- 多签确认
- 提案执行
- 提案撤销

### 5. RealEstateDividendDistributor.sol - 分红系统
房产收益分红分配器，支持：
- ETH 和 ERC20 代币分红
- 拉取式分红（用户主动 claim）
- 推送式分红（批量分发）
- 防重复领取

## 🎯 使用场景

### 场景 1：房产通证化
1. 部署 RealEstateToken 合约
2. 设置身份注册表和合规引擎
3. 投资者完成 KYC 验证
4. Mint 代币给合格投资者
5. 投资者可以在二级市场交易（自动合规检查）

### 场景 2：租金分红
1. 房产产生租金收入
2. 管理员将租金存入 DividendDistributor
3. 投资者按持币比例领取分红
4. 支持 ETH 和 ERC20 代币分红

### 场景 3：合约升级
1. 提交升级提案（需要 3/5 多签）
2. 等待 7 天时间锁
3. 执行升级
4. 新合约继承所有状态

## 📈 Gas 优化

- ✅ 存储槽优化（将多个变量打包到一个 slot）
- ✅ 使用 `unchecked` 块优化算术运算
- ✅ 批量操作减少循环次数
- ✅ 事件索引优化

## 🔍 使用建议

本项目来自真实的生产环境脱敏后的代码。


