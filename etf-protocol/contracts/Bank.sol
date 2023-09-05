// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./TransferHelper.sol";
import "./Formula.sol";

contract Bank is ERC20, Ownable, ReentrancyGuard, Pausable {

    uint256 internal constant FACTOR = 10000;

    uint256 internal constant PRECISION = 10 ** 18;

    uint256 internal constant DEVIATION = 50;

    address[] public assets;

    mapping (address => uint8) public assetDecimals;

    mapping (address => address) public oracles;

    uint256 public totalTokenWeights;

    uint256 public managerRedeemFee = 0;

    address public feeRecipient;

    uint256[] public currentRatios;

    uint256[] public targetRatios;

    bool public isRebalanced;

    event UpdateRatio(uint256[] oldRatios, uint256[] newRatios);

    event Deposit(address indexed user,  uint256 share, address[] tokens, uint256[] amounts, bool isRebalanced);

    event Withdraw(address indexed user, uint256 share, address[] tokens, uint256[] amounts, bool isRebalanced);
    
    constructor(
        address[] memory _assets,
        address[] memory _oracles,
        uint256[] memory _initRatios,
        string memory _symbol, 
        string memory _name
    ) 
        ERC20(_name, _symbol)
    {
        assets = _assets;
        currentRatios = _initRatios;
        uint256 count = _assets.length;
        feeRecipient = msg.sender;
        for(uint256 i = 0; i < count; i++) {
            address _asset = _assets[i];
            oracles[_asset] = _oracles[i];
            assetDecimals[_asset] = ERC20(_asset).decimals();
        }
    }

    modifier onlyEOA {
        require(msg.sender == tx.origin, "EOA");
        _;
    }

    function updateFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function updateFee(uint256 fee) external onlyOwner {
        require(fee > 0 && fee < 1000, "fee is unreasonable");
        managerRedeemFee = fee;
    }

    function updateOracles(address[] memory _oracles) external onlyOwner {
        uint256 count = assets.length;
        for(uint256 i = 0; i < count; i++) {
            oracles[assets[i]] = _oracles[i];
        }
    }

    function deposit(uint256 index, address coin, uint256 amount) external onlyEOA nonReentrant whenNotPaused {
        uint256[] memory ratios = calIncreaseCoins(index, coin, amount);
        uint256 count = ratios.length;
        uint256[] memory amounts = new uint256[](count);
        (uint256[] memory prices, uint8[] memory decimals) = getPrices();
        uint256 value = 0;
        for(uint256 i = 0; i < count; i++) {
            amounts[i] = amount * ratios[i] * assetDecimals[assets[i]] / assetDecimals[coin] / PRECISION;
            value = value + amounts[i] * prices[i] / (10 ** decimals[i]);
            if (amounts[i] > 0) {
                TransferHelper.safeTransferFrom(assets[i], msg.sender, address(this), amounts[i]);
            }
        }
        if (managerRedeemFee > 0) {
            uint256 fee = value * managerRedeemFee / FACTOR;
            value = value - fee;
            _mint(feeRecipient, fee);
        }
        updateRebalanced();
        _mint(msg.sender, value);
        emit Deposit(msg.sender, value, assets, amounts, isRebalanced);
    }

    function updateRebalanced() internal {
        if (isRebalanced) {
            uint256[] memory amounts = getPoolAmounts();
            uint256[] memory deltaAmounts = Formula.calDeltaAmounts(amounts, targetRatios);
            uint256 count = amounts.length;
            uint256 mistake = 0;
            for(uint256 i = 0; i < count; i++) {
                uint256 newAmount = deltaAmounts[i] + amounts[i];
                mistake = deltaAmounts[i] / newAmount * FACTOR <= DEVIATION ? 0 : 1;
            }
            if (mistake == 0) {
                isRebalanced = false;
                currentRatios = targetRatios;
                emit UpdateRatio(currentRatios, targetRatios);
            }
        }
    }

    function calDeltaAmounts() external view returns(uint256[] memory) {
        return Formula.calDeltaAmounts(getPoolAmounts(), targetRatios);
    }
    
    function withdraw(uint256 share) external onlyEOA nonReentrant whenNotPaused {
        (address[] memory coins, uint256[] memory amounts) = calDecreaseCoins(share);
        _burn(msg.sender, share);
        uint256 count = coins.length;
        for(uint256 i = 0; i < count; i++) {
            if (amounts[i] > 0){
                TransferHelper.safeTransfer(coins[i], msg.sender, amounts[i]);
            }
        }
        updateRebalanced();
        emit Withdraw(msg.sender, share, coins, amounts, isRebalanced);
    }

    function adjustTargetRatios(uint256 [] memory _targetRatios) external onlyOwner nonReentrant whenNotPaused {
        targetRatios = _targetRatios;
        isRebalanced = true;
        emit UpdateRatio(currentRatios, _targetRatios);
    }

    function getPrices() public view returns (uint256[] memory, uint8[] memory) {
        uint256 count = assets.length;
        uint256[] memory prices = new uint256[](count);
        uint8[] memory decimals = new uint8[](count);
        for(uint256 i = 0; i < count; i++) {
            AggregatorV3Interface feed = AggregatorV3Interface(oracles[assets[i]]);
            (,int256 price,,,) = feed.latestRoundData();
            prices[i] = uint256(price);
            decimals[i] = feed.decimals();
        }
        return (prices, decimals);
    }

    function getPoolAmounts() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](assets.length);
        for(uint256 i = 0; i < assets.length; i++) {
            amounts[i] = IERC20(assets[i]).balanceOf(address(this));
        }
        return amounts;
    }

    function queryMaxGapCoin() public view returns (uint256, address) {
        (,uint256 index, address coin) = calGapCoin();
        return (index, coin);
    }

    function calGapCoin() internal view returns (uint256[] memory, uint256, address) {
        if (isRebalanced) {
            uint256[] memory amounts =  getPoolAmounts();
            (uint256[] memory prices,) = getPrices();
            (uint256[] memory amt, uint256 index) = Formula.calMaxGapCoin(amounts, targetRatios, prices);
            return (amt, index, assets[index]);
        } else {
            return (currentRatios, 0, assets[0]);
        }
    }

    function calIncreaseCoins(uint256 index, address coin, uint256 amount) public view returns(uint256[] memory) {
        uint256 count = assets.length;
        uint256[] memory ratios = new uint256[](count);
        if (isRebalanced) {
            (uint256[] memory deltaAmounts, uint256 _index, address _coin) = calGapCoin();
            require(_index == index || _coin == coin, "params is wrong");
            uint256[] memory amounts =  getPoolAmounts();
            uint256[] memory increaseAmts = Formula.calIncrease(amounts, targetRatios, deltaAmounts, index, amount);
            uint256 maxAmount = increaseAmts[index];
            for(uint256 i = 0; i < count; i++) {
                ratios[i] = increaseAmts[i] * PRECISION / maxAmount;
            }
        } else {
            require(assets[index] == coin, "params is wrong");
            for(uint256 i = 0; i < count; i++) {
                ratios[i] = currentRatios[i] * PRECISION / currentRatios[0];
            }
        }
        return ratios;
    }

    function calDecreaseCoins(uint256 share) public view returns(address[] memory, uint256[] memory) {
        bool flag = share == totalSupply();
        uint256 count = assets.length;
        address[] memory coins = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 totalSupply = totalSupply();
        if (isRebalanced) {
            uint256[] memory poolAmounts = getPoolAmounts();
            (uint256[] memory prices, ) = getPrices();
            uint256 value = Formula.dot(poolAmounts, prices);
            uint256 lastValue = (1 - share / totalSupply) * value;
            coins = assets;
            amounts = Formula.calDecrease(poolAmounts, targetRatios, prices, lastValue);

        } else {
            if (flag) {
                for(uint256 i = 0; i < count; i++) {
                    coins[i] = assets[i];
                    amounts[i] = IERC20(assets[i]).balanceOf(address(this));
                }
            } else {
                for(uint256 i = 0; i < count; i++) {
                    coins[i] = assets[i];
                    amounts[i] = IERC20(assets[i]).balanceOf(address(this)) * share / totalSupply;
                }
            }
        }
        return (coins, amounts);
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }
}