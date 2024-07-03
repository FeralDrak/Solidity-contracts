pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

interface IForestPair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

library ForestLibrary {
    using SafeMath for uint;

    uint256 public constant FEE_RATE_DENOMINATOR = 1e6;

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint fees) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'ForestLibrary: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'ForestLibrary: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(FEE_RATE_DENOMINATOR.sub(fees));
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(FEE_RATE_DENOMINATOR).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // Feral version
    function getReserves(address pair, bool reverted) internal view returns (uint reserveA, uint reserveB) {
        (uint reserve0, uint reserve1,) = IForestPair(pair).getReserves();
        (reserveA, reserveB) = !reverted ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint amountIn, address[] memory pairpath, bool[] memory reverted, uint[] memory fees) internal view returns (uint[] memory amounts) {
        require(pairpath.length >= 1, 'ForestLibrary: INVALID_PATH');
        amounts = new uint[](pairpath.length + 1);
        amounts[0] = amountIn;
        for (uint i; i < pairpath.length; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(pairpath[i], reverted[i]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, fees[i]);
        }
    }

}

contract Forest is Ownable {

    mapping(address => bool) public allowedTraders;
    address public wallet;
    address public weth;
    uint public minimumBotEthBalance = 0.1 ether; // keep 0.1 bnb in the bot's wallet for the gas fees
    uint public refillBotEthAmount = 0.05 ether;

    address public partnerToken;
    address public partnerWallet;
    uint16 public partnerFeesInBp = 5000; // 50% in basis points


    constructor(address _wallet, address _weth, address _partnerToken, address _partnerWallet, uint16 _partnerFeesInBp) {
        allowedTraders[msg.sender] = true;
        wallet = _wallet;
        weth = _weth;
        partnerToken = _partnerToken;
        partnerWallet = _partnerWallet;
        partnerFeesInBp = _partnerFeesInBp;
    }

    function setAllowedTrader(address trader, bool allow) public onlyOwner {
        require(trader != address(0), "Forest: new trader is the zero address");
        allowedTraders[trader] = allow;
    }

    /**
     * @dev Throws if called by any account other than the trader.
     */
    modifier onlyTrader() {
        require(allowedTraders[msg.sender], "Forest: caller is not a trader");
        _;
    }

    function setWallet(address newWallet) public onlyOwner {
        require(newWallet != address(0), "Forest: new wallet is the zero address");
        wallet = newWallet;
    }

    function setMinimumBotEthBalance(uint _minimumBotEthBalance) public onlyOwner {
        minimumBotEthBalance = _minimumBotEthBalance;
    }

    function setRefillBotEthAmount(uint _refillBotEthAmount) public onlyOwner {
        refillBotEthAmount = _refillBotEthAmount;
    }

    function setPartnerToken(address newToken) public onlyOwner {
        require(newToken != address(0), "Forest: new token is the zero address");
        partnerToken = newToken;
    }

    function setPartnerWallet(address newWallet) public onlyOwner {
        require(newWallet != address(0), "Forest: new wallet is the zero address");
        partnerWallet = newWallet;
    }

    function setPartnerFeesInBp(uint16 feesInBp) public onlyOwner {
        require(partnerFeesInBp <= 10000, "Forest: fees too high");
        partnerFeesInBp = feesInBp;
    }

    function swap(uint amountIn, address[] calldata token, address[] calldata pairpath, bool[] calldata reverted, uint[] calldata fees)
    external
    onlyTrader
    {
        address tokenIn = token[0];
        uint[] memory amounts = ForestLibrary.getAmountsOut(amountIn, pairpath, reverted, fees);
        uint amountOut = amounts[amounts.length - 1];
        require(amountOut >= amountIn, 'Forest: INSUFFICIENT_OUTPUT_AMOUNT');

        // Flash loan
        address pair = pairpath[pairpath.length - 1];
        bytes memory data = abi.encode(token, pairpath, reverted, amounts);
        if (tokenIn == IForestPair(pair).token1()) {
            IForestPair(pair).swap(0, amountOut, address(this), data);
        } else {
            IForestPair(pair).swap(amountOut, 0, address(this), data);
        }
    }

    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory token, address[] memory pairpath, bool[] memory reverted, address _to) internal {
        for (uint i=0; i < pairpath.length - 1; i++) {
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = reverted[i] ? (amountOut, uint(0)) : (uint(0), amountOut);
            address to = i < pairpath.length - 1 ? pairpath[i + 1] : _to;

            // receive partner tokens on contract so we can be tax free
            if (partnerToken == token[i + 1]) {
                to = address(this);
            }

            IForestPair(pairpath[i]).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );

            // send back partner tokens to next pool
            if (partnerToken == token[i + 1]) {
                IERC20(partnerToken).transfer(pairpath[i + 1], IERC20(partnerToken).balanceOf(address(this)));
            }
        }
    }

    receive() external payable {

    }

    fallback(bytes calldata data) external payable returns (bytes memory data1) {
        (address sender, uint amount0, uint amount1, bytes memory data2) = abi.decode(data[4:], (address, uint, uint, bytes));
        (address[] memory token, address[] memory pairpath, bool[] memory reverted, uint[] memory amounts) =
            abi.decode(data2, (address[], address[], bool[], uint[]));

        uint amountIn = amounts[0];
        address tokenIn = token[0];

        // Transfer amountIn to 2nd pair
        IERC20(tokenIn).transfer(pairpath[0], amountIn);

        // Start swaping from 2nd pair
        _swap(amounts, token, pairpath, reverted, pairpath[pairpath.length - 1]);

        uint balanceTokenIn = IERC20(tokenIn).balanceOf(address(this));

        // Refill the bot for gas fees
        if (tokenIn == weth && address(tx.origin).balance < minimumBotEthBalance) {

            uint256 amountToEth = refillBotEthAmount > balanceTokenIn ? balanceTokenIn : refillBotEthAmount;

            // Turn WETH into ETH
            IWETH(weth).withdraw(amountToEth);

            // Send ETH to bot
            payable(tx.origin).transfer(amountToEth);

            // Update WETH balance
            balanceTokenIn = balanceTokenIn - amountToEth;

        }

        if (balanceTokenIn > 0) {

            // Send tokens to partner
            uint amountPartner = balanceTokenIn * partnerFeesInBp / 10000;
            SafeERC20.safeTransfer(IERC20(tokenIn), partnerWallet, amountPartner);

            // Send remaining tokens
            SafeERC20.safeTransfer(IERC20(tokenIn), wallet, balanceTokenIn - amountPartner);
        }

        data1 = data;
    }

    function withdraw() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function withdrawToken(IERC20 _token, uint256 _balance) public onlyOwner {
        SafeERC20.safeTransfer(_token, msg.sender, _balance);
    }

    function withdrawAllToken(IERC20 _token) public onlyOwner {
        SafeERC20.safeTransfer(_token, msg.sender, _token.balanceOf(address(this)));
    }

}


























