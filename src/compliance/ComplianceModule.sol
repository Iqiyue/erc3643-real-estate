// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract ComplianceModule {
    function moduleCheck(address _from, address _to, uint256 _value, address _compliance) external view virtual returns (bool);
    function moduleTransferAction(address _from, address _to, uint256 _value, address _compliance) external virtual;
    function name() external view virtual returns (string memory);
    function isPlugAndPlay() external view virtual returns (bool);
    function bindCompliance(address _compliance) external virtual;
    function unbindCompliance(address _compliance) external virtual;
}
