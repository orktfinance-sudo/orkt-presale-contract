// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ORKT website presale for BNB Chain mainnet (chainId 56).
/// @dev Deploy with the ORKT token, treasury and owner addresses below.
///      The BNB/USD Chainlink feed is intentionally fixed in the source to
///      prevent an incorrect feed address being supplied at deployment.

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

contract ORKTWebsitePresaleV2 {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Official Chainlink BNB/USD proxy on BNB Chain mainnet (chainId 56).
    address public constant BNB_USD_FEED =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    address public immutable owner;
    address public immutable treasury;
    IERC20ORKT public immutable token;
    IChainlinkPriceFeed public immutable priceFeed;

    // $0.001 per ORKT, expressed with 18 decimals.
    uint256 public constant TOKEN_PRICE_USD = 1e15;
    uint256 public constant MAX_BNB_PER_BUY = 1 ether;
    uint256 public constant MAX_ORACLE_AGE = 1 days;
    uint256 public constant SALE_DURATION = 7 days;
    uint256 public constant MAX_TOKENS_FOR_SALE = 20_000_000 ether;

    uint256 public totalSold;
    uint256 public totalInventoryAdded;
    uint256 public saleEnd;

    bool public saleStarted;
    bool public saleFinalized;
    bool public unsoldTokensProcessed;

    uint256 private locked = 1;

    event InventoryAdded(uint256 amount);
    event InventoryWithdrawn(uint256 amount);
    event SaleStarted(uint256 saleEnd);
    event TokensPurchased(address indexed buyer, uint256 bnbPaid, uint256 tokensReceived);
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
        address treasuryAddress,
        address ownerAddress
    ) {
        require(tokenAddress != address(0), "Invalid token");
        require(treasuryAddress != address(0), "Invalid treasury");
        require(ownerAddress != address(0), "Invalid owner");
        require(tokenAddress.code.length > 0, "Token is not a contract");
        require(BNB_USD_FEED.code.length > 0, "Chainlink feed not deployed");
        require(IERC20ORKT(tokenAddress).decimals() == 18, "Token must have 18 decimals");
        require(IChainlinkPriceFeed(BNB_USD_FEED).decimals() == 8, "Unexpected feed decimals");

        token = IERC20ORKT(tokenAddress);
        priceFeed = IChainlinkPriceFeed(BNB_USD_FEED);
        treasury = treasuryAddress;
        owner = ownerAddress;
    }

    function getBNBPriceWad() public view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(roundId > 0, "Invalid oracle round");
        require(answer > 0, "Invalid oracle price");
        require(updatedAt != 0 && updatedAt <= block.timestamp, "Invalid oracle timestamp");
        require(block.timestamp - updatedAt <= MAX_ORACLE_AGE, "Stale oracle price");
        require(answeredInRound >= roundId, "Incomplete oracle round");

        // This BNB/USD feed is verified to use 8 decimals.
        return uint256(answer) * 1e10;
    }

    function quoteTokens(uint256 bnbAmount) public view returns (uint256) {
        if (bnbAmount == 0) return 0;
        require(bnbAmount <= MAX_BNB_PER_BUY, "Maximum purchase is 1 BNB");
        uint256 bnbPriceWad = getBNBPriceWad();
        return (bnbAmount * bnbPriceWad) / TOKEN_PRICE_USD;
    }

    function minimumBNBForNonZeroQuote() external view returns (uint256) {
        uint256 bnbPriceWad = getBNBPriceWad();
        return TOKEN_PRICE_USD / bnbPriceWad
            + (TOKEN_PRICE_USD % bnbPriceWad == 0 ? 0 : 1);
    }

    /// @notice Add inventory. May be called again during the sale to replenish stock.
    /// @dev Owner must first approve this contract to spend the ORKT amount.
    function addInventory(uint256 amount) external onlyOwner nonReentrant {
        require(!saleFinalized, "Sale already finalized");
        require(amount > 0, "Amount must be greater than zero");
        require(totalInventoryAdded + amount <= MAX_TOKENS_FOR_SALE, "Sale allocation exceeded");

        uint256 beforeBalance = token.balanceOf(address(this));
        _safeTransferFrom(address(token), owner, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        require(received == amount, "Incorrect inventory received");

        totalInventoryAdded += amount;
        emit InventoryAdded(amount);
    }

    /// @notice Recover inventory only before the sale has ever started.
    function withdrawInventory(uint256 amount) external onlyOwner nonReentrant {
        require(!saleStarted, "Sale already started");
        require(!saleFinalized, "Sale already finalized");
        require(amount > 0 && amount <= token.balanceOf(address(this)), "Invalid amount");
        require(amount <= totalInventoryAdded, "Amount exceeds recorded inventory");

        totalInventoryAdded -= amount;
        _safeTransfer(address(token), owner, amount);
        emit InventoryWithdrawn(amount);
    }

    function startSale() external onlyOwner {
        require(!saleStarted, "Sale already started");
        require(!saleFinalized, "Sale already finalized");
        require(token.balanceOf(address(this)) > 0, "No inventory available");

        // Validate the oracle before activating the sale.
        getBNBPriceWad();

        saleStarted = true;
        saleEnd = block.timestamp + SALE_DURATION;
        emit SaleStarted(saleEnd);
    }

    function buy(uint256 minTokensOut) external payable nonReentrant {
        require(saleStarted, "Sale is not active");
        require(!saleFinalized, "Sale already finalized");
        require(block.timestamp <= saleEnd, "Sale period ended");
        require(msg.value > 0, "BNB amount must be greater than zero");
        require(msg.value <= MAX_BNB_PER_BUY, "Maximum purchase is 1 BNB");

        uint256 tokenAmount = quoteTokens(msg.value);
        require(tokenAmount > 0, "Purchase amount too small");
        require(tokenAmount >= minTokensOut, "Slippage limit exceeded");
        require(totalSold + tokenAmount <= MAX_TOKENS_FOR_SALE, "Sale allocation sold out");
        require(token.balanceOf(address(this)) >= tokenAmount, "Insufficient token inventory");

        uint256 buyerBalanceBefore = token.balanceOf(msg.sender);
        totalSold += tokenAmount;
        _safeTransfer(address(token), msg.sender, tokenAmount);
        uint256 buyerBalanceAfter = token.balanceOf(msg.sender);
        require(buyerBalanceAfter - buyerBalanceBefore == tokenAmount, "Incorrect token amount received");

        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }

    function finalizeSale() external onlyOwner {
        require(saleStarted, "Sale has not started");
        require(!saleFinalized, "Sale already finalized");
        require(
            block.timestamp > saleEnd || totalSold == MAX_TOKENS_FOR_SALE,
            "Sale is still active"
        );
        saleFinalized = true;
        emit SaleFinalized();
    }

    function withdrawBNB() external onlyOwner nonReentrant {
        require(saleFinalized, "Sale is not finalized");
        uint256 amount = address(this).balance;
        require(amount > 0, "No BNB to withdraw");

        (bool success, ) = payable(treasury).call{value: amount}("");
        require(success, "BNB transfer failed");
        emit BNBWithdrawn(treasury, amount);
    }

    function burnUnsoldTokens() external onlyOwner nonReentrant {
        require(saleFinalized, "Sale is not finalized");
        require(!unsoldTokensProcessed, "Unsold tokens already processed");

        unsoldTokensProcessed = true;
        uint256 remainingTokens = token.balanceOf(address(this));
        if (remainingTokens > 0) {
            _safeTransfer(address(token), DEAD, remainingTokens);
        }
        emit UnsoldTokensBurned(remainingTokens);
    }

    function _safeTransfer(address tokenAddress, address to, uint256 amount) internal {
        (bool success, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(IERC20ORKT.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool)))), "Token transfer failed");
    }

    function _safeTransferFrom(address tokenAddress, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(IERC20ORKT.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool)))), "Token transferFrom failed");
    }

    receive() external payable {
        revert("Use the buy function");
    }

    fallback() external payable {
        revert("Invalid function");
    }
}
