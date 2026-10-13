pragma solidity 0.6.4;

import "./System.sol";
import "./interface/0.6.x/IParamSubscriber.sol";
import "./interface/0.6.x/IApplication.sol";

contract GovHub is System, IApplication {
    uint32 public constant ERROR_TARGET_NOT_CONTRACT = 101;
    uint32 public constant ERROR_TARGET_CONTRACT_FAIL = 102;

    event failReasonWithStr(string message);
    event failReasonWithBytes(bytes message);
    event paramChange(string key, bytes value);  // @dev deprecated

    struct ParamChangePackage {
        string key;
        bytes value;
        address target;
    }

    function handleSynPackage(
        uint8,
        bytes calldata msgBytes
    ) external override onlyCrossChainContract returns (bytes memory responsePayload) {
        revert("deprecated");
    }

    // should not happen
    function handleAckPackage(uint8, bytes calldata) external override onlyCrossChainContract {
        revert("deprecated");
    }

    // should not happen
    function handleFailAckPackage(uint8, bytes calldata) external override onlyCrossChainContract {
        revert("deprecated");
    }

    // A failed update reverts the whole call. Swallowing it
    // let the timelock and governor mark an unapplied action as executed, broke
    // the atomicity of multi-action proposals and left no retry. The target's
    // revert data is bubbled unchanged.
    function updateParam(string calldata key, bytes calldata value, address target) external onlyGovernorTimelock {
        require(isContract(target), "the target is not a contract");
        IParamSubscriber(target).updateParam(key, value);
    }
}
