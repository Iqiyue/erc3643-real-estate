// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ComplianceModule.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ModularCompliance.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../token/RealEstateToken.sol";

/**
 * @title InvestorLimitsModule
 * @notice 投资者限制模块,管理投资者数量和持币量限制
 * @dev 实现 ComplianceModule 接口,提供投资者数量、持币量和最小投资额限制
 */
contract InvestorLimitsModule is ComplianceModule, Ownable {
    // 常量定义
    uint256 public constant BASIS_POINTS = 10000;

    address public compliance;

    uint256 public maxInvestors;
    uint256 public maxHoldingPercentage; // 基数 10000 (例如 2000 = 20%)
    uint256 public minInvestmentAmount;

    // 自定义错误
    error InvalidPercentage(uint256 percentage);
    error ComplianceAlreadyBound();
    error ComplianceNotBound();

    event MaxInvestorsSet(uint256 maxInvestors);
    event MaxHoldingPercentageSet(uint256 maxHoldingPercentage);
    event MinInvestmentAmountSet(uint256 minInvestmentAmount);

    /**
     * @notice 构造函数
     * @param _maxInvestors 最大投资者数量
     * @param _maxHoldingPercentage 单人最大持币百分比(基数10000)
     * @param _minInvestmentAmount 最小投资金额
     */
    constructor(
        uint256 _maxInvestors,
        uint256 _maxHoldingPercentage,
        uint256 _minInvestmentAmount
    ) Ownable(msg.sender) {
        if (_maxHoldingPercentage > BASIS_POINTS) revert InvalidPercentage(_maxHoldingPercentage);
        maxInvestors = _maxInvestors;
        maxHoldingPercentage = _maxHoldingPercentage;
        minInvestmentAmount = _minInvestmentAmount;
    }

    function moduleCheck(
        address _from,
        address _to,
        uint256 _value,
        address _complianceAddr
    ) external view override returns (bool) {
        ModularCompliance complianceContract = ModularCompliance(_complianceAddr);
        RealEstateToken token = RealEstateToken(complianceContract.tokenBound());

        // Mint 操作
        if (_from == address(0)) {
            // 检查最小投资金额
            if (_value < minInvestmentAmount) {
                return false;
            }

            // 检查投资者数量限制
            if (token.balanceOf(_to) == 0) {
                if (token.investorCount() >= maxInvestors) {
                    return false;
                }
            }

            // 检查最大持币量 (如果已有其他投资者)
            uint256 newMintBalance = token.balanceOf(_to) + _value;
            uint256 newTotalSupply = token.totalSupply() + _value;
            // 只有当已经有其他投资者时才检查最大持币比例
            if (newTotalSupply > 0 && token.investorCount() > 0 && (newMintBalance * BASIS_POINTS) / newTotalSupply > maxHoldingPercentage) {
                return false;
            }

            return true;
        }

        // Burn 操作
        if (_to == address(0)) {
            return true;
        }

        // 普通转账 - 检查接收方最大持币量
        uint256 newBalance = token.balanceOf(_to) + _value;
        uint256 totalSupply = token.totalSupply();
        if (totalSupply > 0 && (newBalance * BASIS_POINTS) / totalSupply > maxHoldingPercentage) {
            return false;
        }

        return true;
    }

    function moduleTransferAction(
        address,
        address,
        uint256,
        address
    ) external pure override {
        // No state mutation required for this module after transfer.
    }

    function setMaxInvestors(uint256 _maxInvestors) external onlyOwner {
        require(_maxInvestors > 0, "Max investors must be positive");
        require(_maxInvestors <= 10000, "Max investors too large"); // LOW-3: 合理性上限
        maxInvestors = _maxInvestors;
        emit MaxInvestorsSet(_maxInvestors);
    }

    function setMaxHoldingPercentage(uint256 _maxHoldingPercentage) external onlyOwner {
        require(_maxHoldingPercentage <= 10000, "Invalid percentage");
        maxHoldingPercentage = _maxHoldingPercentage;
        emit MaxHoldingPercentageSet(_maxHoldingPercentage);
    }

    function setMinInvestmentAmount(uint256 _minInvestmentAmount) external onlyOwner {
        minInvestmentAmount = _minInvestmentAmount;
        emit MinInvestmentAmountSet(_minInvestmentAmount);
    }

    function name() external pure override returns (string memory) {
        return "InvestorLimitsModule";
    }

    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    function bindCompliance(address _compliance) external override {
        require(msg.sender == _compliance || msg.sender == owner(), "Unauthorized binder");
        require(compliance == address(0), "Already bound");
        compliance = _compliance;
    }

    function unbindCompliance(address _compliance) external override {
        require(msg.sender == _compliance || msg.sender == owner(), "Unauthorized unbinder");
        require(compliance == _compliance, "Not bound to this compliance");
        compliance = address(0);
    }
}
