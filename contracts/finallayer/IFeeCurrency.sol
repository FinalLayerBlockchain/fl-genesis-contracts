// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

/**
 * @dev Final Layer fee currencies (gas paid in an ERC-20 token), modelled on
 * Celo's fee abstraction. A token can pay for gas only after governance has
 * listed it in the FeeCurrencyDirectory.
 *
 * The node calls debitGasFees before running the transaction and
 * creditGasFees after it, both with msg.sender == address(0) (no account can
 * produce that caller). Every amount the node debits is credited back in the
 * same transaction: the unused part to the sender, the fee to the block
 * producer.
 */
interface IFeeCurrency {
    /// @dev Remove `value` from `from`. Must revert if `from` cannot pay.
    function debitGasFees(address from, uint256 value) external;

    /// @dev Add `amounts[i]` to `recipients[i]`. Must revert if the lengths differ.
    function creditGasFees(address[] calldata recipients, uint256[] calldata amounts) external;
}

/**
 * @dev Price source for a fee currency. The rate is how many of the token's
 * smallest units equal one wei of FL:
 *     tokenAmount = flAmount * numerator / denominator
 * A source must revert (never return zero) when it has no valid price, which
 * turns the token off as a fee currency instead of mispricing gas.
 */
interface IFeeCurrencyOracle {
    function getExchangeRate(address token) external view returns (uint256 numerator, uint256 denominator);
}
