// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { StandardERC20 } from "./StandardERC20.sol";

/// @title TokenFactory
/// @notice Deploys standard ERC-20 tokens for a flat, immutable fee paid in the
///         chain's native currency (DOGE on DogeOS) and keeps an on-chain registry.
/// @dev Non-upgradeable. The fee and fee receiver are immutable. There are no
///      owner-only functions and the contract never holds user funds: the fee is
///      forwarded to the fee receiver in the same transaction.
contract TokenFactory is ReentrancyGuard {
    /// @notice Absolute upper bound for the creation fee. A deployed factory can
    ///         never charge more than this, even if governance tooling is added later.
    uint256 public constant MAX_FEE = 1000 ether;

    /// @notice Fee charged for every token deployment, in wei of the native token.
    uint256 public immutable flatFee;

    /// @notice Address that receives creation fees.
    address payable public immutable feeReceiver;

    /// @notice Public on-chain registry entry for a created token.
    struct TokenInfo {
        address token;
        address creator;
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
        uint64 createdAt;
    }

    TokenInfo[] private _tokens;
    mapping(address creator => TokenInfo[] tokens) private _tokensByCreator;

    /// @param tokenIndex Index in the global registry.
    /// @param token Address of the newly deployed ERC-20.
    /// @param creator Caller that paid the fee and received 100% of the supply.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param decimals Token decimals.
    /// @param initialSupply Entire supply in smallest token units.
    /// @param feePaid Fee forwarded to the fee receiver, in wei.
    event TokenCreated(
        uint256 indexed tokenIndex,
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint8 decimals,
        uint256 initialSupply,
        uint256 feePaid
    );

    error InvalidFeeReceiver();
    error FeeAboveMaximum();
    error IncorrectFee(uint256 expected, uint256 received);
    error FeeTransferFailed();

    constructor(address payable feeReceiver_, uint256 flatFee_) {
        if (feeReceiver_ == address(0)) revert InvalidFeeReceiver();
        if (flatFee_ > MAX_FEE) revert FeeAboveMaximum();

        feeReceiver = feeReceiver_;
        flatFee = flatFee_;
    }

    /// @notice Deploy a new StandardERC20 and register it.
    /// @dev initialSupply is in smallest token units, not whole tokens.
    ///      The caller must send exactly flatFee wei.
    /// @return token Address of the deployed token.
    function createToken(string calldata name, string calldata symbol, uint8 decimals, uint256 initialSupply)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value != flatFee) revert IncorrectFee(flatFee, msg.value);

        StandardERC20 deployed = new StandardERC20(name, symbol, decimals, initialSupply, msg.sender);
        token = address(deployed);

        TokenInfo memory info = TokenInfo({
            token: token,
            creator: msg.sender,
            name: name,
            symbol: symbol,
            decimals: decimals,
            initialSupply: initialSupply,
            createdAt: uint64(block.timestamp)
        });

        uint256 tokenIndex = _tokens.length;
        _tokens.push(info);
        _tokensByCreator[msg.sender].push(info);

        emit TokenCreated(tokenIndex, token, msg.sender, name, symbol, decimals, initialSupply, msg.value);

        // Checks-effects-interactions: registry is updated before forwarding value.
        // The nonReentrant guard also blocks re-entrant token creation.
        (bool sent,) = feeReceiver.call{ value: msg.value }("");
        if (!sent) revert FeeTransferFailed();
    }

    /// @notice Total number of tokens created through this factory.
    function getTokensCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @notice Paginated read of the global token registry.
    /// @param offset Zero-based index of the first item.
    /// @param limit Maximum number of items to return.
    function getTokensPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (TokenInfo[] memory page)
    {
        uint256 total = _tokens.length;
        if (limit == 0 || offset >= total) return new TokenInfo[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new TokenInfo[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _tokens[i];
        }
    }

    /// @notice All tokens created by a specific address, in creation order.
    function getTokensByCreator(address creator) external view returns (TokenInfo[] memory) {
        return _tokensByCreator[creator];
    }

    /// @notice Paginated version of getTokensByCreator.
    function getTokensByCreatorPaginated(address creator, uint256 offset, uint256 limit)
        external
        view
        returns (TokenInfo[] memory page)
    {
        TokenInfo[] storage owned = _tokensByCreator[creator];
        uint256 total = owned.length;
        if (limit == 0 || offset >= total) return new TokenInfo[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new TokenInfo[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = owned[i];
        }
    }
}