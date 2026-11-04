
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20ORKT {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IChainlinkPriceFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract ORKTWebsitePresale {
    address public constant DEAD =
        0x000000000000000000000000000000000000dEaD;

    address public immutable owner;
    address public immutable treasury;

    IERC20ORKT public immutable token;
    IChainlinkPriceFeed public immutable priceFeed;

    // $0.001 per ORKT token, using 18 decimals.
    uint256 public constant TOKEN_PRICE_USD = 1e15;

    // Maximum BNB per purchase transaction.
    uint256 public constant MAX_BNB_PER_BUY = 1 ether;

    // Maximum accepted age for the Chainlink price.
    uint256 public constant MAX_ORACLE_AGE = 1 days;

    uint256 public totalSold;

    bool public saleStarted;
    bool public saleFinalized;
    bool public unsoldTokensProcessed;

    uint256 private locked = 1;

    event InventoryAdded(uint256 amount);
    event SaleStarted();
    event TokensPurchased(
        address indexed buyer,
        uint256 bnbPaid,
        uint256 tokensReceived
    );
    event SaleFinalized();
    event BNBWithdrawn(address indexed treasury, uint256 amount);
    event UnsoldTokensBurned(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier nonReentrant() {
        require(locked == 1, "Reentrant call");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address tokenAddress,
        address feedAddress,
        address treasuryAddress,
        address ownerAddress
    ) {
        require(tokenAddress != address(0), "Invalid token");
        require(feedAddress != address(0), "Invalid price feed");
        require(treasuryAddress != address(0), "Invalid treasury");
        require(ownerAddress != address(0), "Invalid owner");

        token = IERC20ORKT(tokenAddress);
        priceFeed = IChainlinkPriceFeed(feedAddress);

        require(
            IERC20ORKT(tokenAddress).decimals() == 18,
            "Token must have 18 decimals"
        );

        owner = ownerAddress;
        treasury = treasuryAddress;
    }

    function getBNBPriceWad() public view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(answer > 0, "Invalid oracle price");
        require(updatedAt != 0, "Invalid oracle timestamp");
        require(updatedAt <= block.timestamp, "Future oracle timestamp");
        require(
            block.timestamp - updatedAt <= MAX_ORACLE_AGE,
            "Stale oracle price"
        );
        require(answeredInRound >= roundId, "Incomplete oracle round");

        uint8 feedDecimals = priceFeed.decimals();

        if (feedDecimals <= 18) {
            return uint256(answer) * (10 ** (18 - uint256(feedDecimals)));
        }

        return uint256(answer) / (10 ** (uint256(feedDecimals) - 18));
    }

    function quoteTokens(uint256 bnbAmount)
        public
        view
        returns (uint256)
    {
        if (bnbAmount == 0) {
            return 0;
        }

        uint256 bnbPriceWad = getBNBPriceWad();

        return (bnbAmount * bnbPriceWad) / TOKEN_PRICE_USD;
    }

    function minimumBNBForNonZeroQuote()
        external
        view
        returns (uint256)
    {
        uint256 bnbPriceWad = getBNBPriceWad();

        return (TOKEN_PRICE_USD / bnbPriceWad) + 1;
    }

    function addInventory(uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(!saleFinalized, "Sale already finalized");
        require(amount > 0, "Amount must be greater than zero");

        uint256 balanceBefore = token.balanceOf(address(this));

        _safeTransferFrom(address(token), owner, address(this), amount);

        uint256 balanceAfter = token.balanceOf(address(this));

        require(
            balanceAfter - balanceBefore == amount,
            "Incorrect inventory received"
        );

        emit InventoryAdded(amount);
    }

    function startSale() external onlyOwner {
        require(!saleStarted, "Sale already started");
        require(!saleFinalized, "Sale already finalized");
        require(
            token.balanceOf(address(this)) > 0,
            "No inventory available"
        );

        saleStarted = true;

        emit SaleStarted();
    }

    function buy(uint256 minTokensOut)
        external
        payable
        nonReentrant
    {
        require(saleStarted, "Sale is not active");
        require(!saleFinalized, "Sale already finalized");
        require(msg.value > 0, "BNB amount must be greater than zero");
        require(
            msg.value <= MAX_BNB_PER_BUY,
            "Maximum purchase is 1 BNB"
        );

        uint256 tokenAmount = quoteTokens(msg.value);

        require(tokenAmount > 0, "Purchase amount too small");
        require(
            tokenAmount >= minTokensOut,
            "Slippage limit exceeded"
        );

        uint256 availableTokens = token.balanceOf(address(this));

        require(
            availableTokens >= tokenAmount,
            "Insufficient token inventory"
        );

        uint256 buyerBalanceBefore = token.balanceOf(msg.sender);

        totalSold += tokenAmount;

        _safeTransfer(address(token), msg.sender, tokenAmount);

        uint256 buyerBalanceAfter = token.balanceOf(msg.sender);

        require(
            buyerBalanceAfter - buyerBalanceBefore == tokenAmount,
            "Incorrect token amount received"
        );

        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }

    function finalizeSale() external onlyOwner {
        require(saleStarted, "Sale has not started");
        require(!saleFinalized, "Sale already finalized");

        saleFinalized = true;

        emit SaleFinalized();
    }

    function withdrawBNB()
        external
        onlyOwner
        nonReentrant
    {
        require(saleFinalized, "Sale is not finalized");

        uint256 amount = address(this).balance;

        require(amount > 0, "No BNB to withdraw");

        (bool success, ) = payable(treasury).call{value: amount}("");

        require(success, "BNB transfer failed");

        emit BNBWithdrawn(treasury, amount);
    }

    function burnUnsoldTokens()
        external
        onlyOwner
        nonReentrant
    {
        require(saleFinalized, "Sale is not finalized");
        require(!unsoldTokensProcessed, "Unsold tokens already processed");

        unsoldTokensProcessed = true;

        uint256 remainingTokens = token.balanceOf(address(this));

        if (remainingTokens > 0) {
            _safeTransfer(address(token), DEAD, remainingTokens);
        }

        emit UnsoldTokensBurned(remainingTokens);
    }

    function _safeTransfer(
        address tokenAddress,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(
                IERC20ORKT.transfer.selector,
                to,
                amount
            )
        );

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token transfer failed"
        );
    }

    function _safeTransferFrom(
        address tokenAddress,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(
                IERC20ORKT.transferFrom.selector,
                from,
                to,
                amount
            )
        );

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token transferFrom failed"
        );
    }

    receive() external payable {
        revert("Use the buy function");
    }

    fallback() external payable {
        revert("Invalid function");
    }
}
