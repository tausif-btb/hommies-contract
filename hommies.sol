pragma solidity ^0.8.20;

contract Hommies is
    ERC20,
    ERC20Burnable,
    Ownable,
    ERC20Permit,
    AccessControl,
    Pausable
{
    uint8 public buyTax = 4;
    uint8 public sellTax = 8;
    uint8 public transferTax = 0;

    uint256 public initialSupply = 700000000;
    uint256 public maxSupply = 10000000000;

    address public rewardWallet;
    address public revenueWallet;
    address public uniswapPair;

    uint256 public revenueThreshold = 10000000;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    IUniswapV2Router02 public uniswapRouter;
    IUniswapV2Factory private uniswapFactory;
    IUniswapV2Pair private uniswapV2Pair;

    constructor(
        address _rewardWallet,
        address _revenueWallet,
        address _minterWallet
    ) ERC20("Hommies", "HOMMIES") Ownable(msg.sender) ERC20Permit("Hommies") {
        require(_rewardWallet != address(0), "Invalid Reward Wallet Address");
        require(_revenueWallet != address(0), "Invalid Revenue Wallet Address");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, _minterWallet);

        rewardWallet = _rewardWallet;
        revenueWallet = _revenueWallet;

        uniswapRouter = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        ); //Uniswap Router Address
        uniswapFactory = IUniswapV2Factory(
            0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f
        ); //Uniswap Factory Address
        uniswapPair = uniswapFactory.createPair(
            address(this),
            uniswapRouter.WETH()
        );
        uniswapV2Pair = IUniswapV2Pair(uniswapPair);
        _mint(msg.sender, initialSupply * 10**decimals());
    }

    function mint(address to, uint256 amount) public whenNotPaused {
        require(hasRole(MINTER_ROLE, msg.sender), "Caller is not a minter");
        require(to != address(0), "Invalid Wallet Address");
        require(
            totalSupply() + amount <= maxSupply * 10**decimals(),
            "ERC20: max supply exceeded"
        );
        _mint(to, amount);
    }

    function setRewardWallet(address _rewardWallet) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        require(_rewardWallet != address(0), "Invalid Wallet Address");
        rewardWallet = _rewardWallet;
    }

    function setRevenueWallet(address _revenueWallet) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        require(_revenueWallet != address(0), "Invalid Wallet Address");
        revenueWallet = _revenueWallet;
    }

    function setThresholdLimit(uint256 _limit) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        revenueThreshold = _limit;
    }

    function setTaxes(
        uint8 _buyTax,
        uint8 _sellTax,
        uint8 _transferTax
    ) external {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        buyTax = _buyTax;
        sellTax = _sellTax;
        transferTax = _transferTax;
    }

    function transfer(address recipient, uint amount)
        public
        override
        whenNotPaused
        returns (bool)
    {
        require(recipient != address(0), "Invalid Address");
        require(amount > 0, "Amount should be greater than zero.");
        return _taxedTransfer(msg.sender, recipient, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) public override whenNotPaused returns (bool) {
        require(sender != address(0), "Invalid Address");
        require(recipient != address(0), "Invalid Address");
        uint256 currentAllowance = allowance(sender, msg.sender);
        require(
            currentAllowance >= amount,
            "ERC20: transfer amount exceeds allowance"
        );
        require(amount > 0, "Amount should be greater than zero.");
        _taxedTransfer(sender, recipient, amount);
        return true;
    }

    function _taxedTransfer(
        address sender,
        address recipient,
        uint amount
    ) internal whenNotPaused returns (bool) {
        require(sender != address(0), "Invalid Address");
        require(recipient != address(0), "Invalid Address");
        require(
            amount > 0,
            "Amount should be greater than zero for transaction."
        );

        uint256 totalTax = 0;
        uint8 taxRate = transferTax;
        uint256 amountAfterTax = amount;

        if (sender == uniswapPair && recipient != address(uniswapRouter)) {
            //Buy Transaction
            taxRate = buyTax;
        } else if (recipient == uniswapPair) {
            //Sell Transaction
            taxRate = sellTax;
        } else {
            //Other Transaction
            taxRate = transferTax;
        }

        totalTax = calculateTax(amount, taxRate);
        amountAfterTax -= totalTax;
        uint256 rewardTax = totalTax / 2;
        uint256 revenueTax = totalTax / 2;

        super._transfer(sender, address(this), revenueTax);
        super._transfer(sender, rewardWallet, rewardTax);
        super._transfer(sender, recipient, amountAfterTax);

        uint256 currentContractBalance = getContractBalance();
        uint256 minAmountBack = 0;
        if (currentContractBalance > revenueThreshold * 10**decimals()) {
            minAmountBack = getMinAmountBack(
                revenueThreshold * 10**decimals(),
                1000
            ); //Swap with max 10% slippage
        }
        uint256 minExpectedWETH = 1e17; //0.1 ETH
        if (
            (currentContractBalance > revenueThreshold * 10**decimals()) &&
            (minAmountBack > minExpectedWETH)
        ) {
            swapTokensForEth(revenueThreshold * 10**decimals(), minAmountBack);
        }
        return true;
    }

    function calculateTax(uint256 amount, uint8 _taxRate)
        private
        pure
        returns (uint256)
    {
        return (amount * _taxRate) / 100;
    }

    function getContractBalance() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function swapTokensForEth(uint256 _tokenAmount, uint256 _minAmountBack)
        private
        whenNotPaused
    {
        IERC20(address(this)).approve(address(uniswapRouter), _tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        // Make the swap
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _tokenAmount,
            _minAmountBack,
            path,
            revenueWallet,
            block.timestamp
        );
    }

    function getMinAmountBack(uint256 amountIn, uint256 slippage)
        private
        view
        returns (uint256 minAmountOut)
    {
        require(slippage <= 10000, "Slippage too high"); // Slippage cannot be more than 100%

        (uint112 reserve0, uint112 reserve1, ) = uniswapV2Pair.getReserves();
        address token0 = uniswapV2Pair.token0();
        address token1 = uniswapV2Pair.token1();

        uint256 rawAmountOut;
        if (address(this) == token0) {
            // Sorting tokens according to their addresses
            rawAmountOut = uniswapRouter.getAmountOut(
                amountIn,
                reserve0,
                reserve1
            );
        } else if (address(this) == token1) {
            rawAmountOut = uniswapRouter.getAmountOut(
                amountIn,
                reserve1,
                reserve0
            );
        } else {
            revert("Invalid token");
        }
        uint256 slippageAmount = (rawAmountOut * slippage) / 10000;
        minAmountOut = rawAmountOut - slippageAmount;
    }

    function pauseContract() public whenNotPaused returns (bool) {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        _pause();
        return true;
    }

    function unpauseContract() public whenPaused returns (bool) {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        _unpause();
        return true;
    }

    function withdrawTokens(address _tokenContract) external whenNotPaused {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        IERC20 token = IERC20(_tokenContract);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(token.transfer(revenueWallet, tokenBalance), "Transfer failed");
    }
}