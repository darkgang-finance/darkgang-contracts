// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IRegulationStats.sol";
import "./interfaces/IRewardPool.sol";

// DARKGANG FINANCE
contract Treasury is ITreasury, ContractGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private epoch_ = 0;
    uint256 private epochLength_ = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public darkg;
    address public bond;

    address public override boardroom;
    uint256 public boardroomWithdrawFee;

    address public darkgOracle;

    // price
    uint256 public darkgPriceOne;
    uint256 public darkgPriceCeiling;

    uint256 public seigniorageSaved;

    uint256 public nextSupplyTarget;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of DARKG price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    uint256 public override previousEpochDarkgPrice;
    uint256 public allocateSeigniorageSalary;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra DARKG during debt phase

    address public override daoFund;
    uint256 public override daoFundSharedPercent; // 3000 (30%)

    address public override marketingFund;
    uint256 public override marketingFundSharedPercent; // 1000 (10%)

    address public override insuranceFund;
    uint256 public override insuranceFundSharedPercent; // 2000 (20%)

    address public regulationStats;
    address public skygRewardPool;
    uint256 public skygRewardPoolExpansionRate;
    uint256 public skygRewardPoolContractionRate;

    address[] public darkgLockedAccounts;

    /* =================== Added variables =================== */
    // ...

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 darkgAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 darkgAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event FundingAdded(uint256 indexed epoch, uint256 timestamp, uint256 price, uint256 expanded, uint256 boardroomFunded, uint256 daoFunded, uint256 marketingFunded, uint256 insuranceFund);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(now >= _nextEpochPoint, "Treasury: not opened yet");

        _;

        lastEpochTime = _nextEpochPoint;
        epoch_ = epoch_.add(1);
        epochSupplyContractionLeft = (getDarkgPrice() > darkgPriceCeiling) ? 0 : IERC20(darkg).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(darkg).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function epoch() public override view returns (uint256) {
        return epoch_;
    }

    function nextEpochPoint() public override view returns (uint256) {
        return lastEpochTime.add(nextEpochLength());
    }

    function nextEpochLength() public override view returns (uint256) {
        return epochLength_;
    }

    function getPegPrice() external override view returns (int256) {
        return IOracle(darkgOracle).getPegPrice();
    }

    function getPegPriceUpdated() external override view returns (int256) {
        return IOracle(darkgOracle).getPegPriceUpdated();
    }

    // oracle
    function getDarkgPrice() public override view returns (uint256 darkgPrice) {
        try IOracle(darkgOracle).consult(darkg, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult DARKG price from the oracle");
        }
    }

    function getDarkgUpdatedPrice() public override view returns (uint256 _darkgPrice) {
        try IOracle(darkgOracle).twap(darkg, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult DARKG price from the oracle");
        }
    }

    function boardroomSharedPercent() external override view returns (uint256) {
        return uint256(10000).sub(daoFundSharedPercent).sub(marketingFundSharedPercent).sub(insuranceFundSharedPercent);
    }

    // budget
    function getReserve() external view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableDarkgLeft() external view returns (uint256 _burnableDarkgLeft) {
        uint256 _darkgPrice = getDarkgPrice();
        if (_darkgPrice <= darkgPriceOne) {
            uint256 _bondMaxSupply = IERC20(darkg).totalSupply().mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableDarkg = _maxMintableBond.mul(getBondDiscountRate()).div(1e18);
                _burnableDarkgLeft = Math.min(epochSupplyContractionLeft, _maxBurnableDarkg);
            }
        }
    }

    function getRedeemableBonds() external view returns (uint256 _redeemableBonds) {
        uint256 _darkgPrice = getDarkgPrice();
        if (_darkgPrice > darkgPriceCeiling) {
            uint256 _totalDarkg = IERC20(darkg).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalDarkg.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public override view returns (uint256 _rate) {
        uint256 _darkgPrice = getDarkgPrice();
        if (_darkgPrice <= darkgPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = darkgPriceOne;
            } else {
                uint256 _bondAmount = darkgPriceOne.mul(1e18).div(_darkgPrice); // to burn 1 DARKG
                uint256 _discountAmount = _bondAmount.sub(darkgPriceOne).mul(discountPercent).div(10000);
                _rate = darkgPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public override view returns (uint256 _rate) {
        uint256 _darkgPrice = getDarkgPrice();
        if (_darkgPrice > darkgPriceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = darkgPriceOne;
            } else {
                uint256 _premiumAmount = _darkgPrice.sub(darkgPriceOne).mul(premiumPercent).div(10000);
                _rate = darkgPriceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getDarkgLockedBalance() public override view returns (uint256 _lockedBalance) {
        uint256 _length = darkgLockedAccounts.length;
        IERC20 _darkg = IERC20(darkg);
        for (uint256 i = 0; i < _length; i++) {
            _lockedBalance = _lockedBalance.add(_darkg.balanceOf(darkgLockedAccounts[i]));
        }
    }

    function getDarkgCirculatingSupply() public override view returns (uint256) {
        return IERC20(darkg).totalSupply().sub(getDarkgLockedBalance());
    }

    function getNextExpansionRate() public override view returns (uint256 _rate) {
        if (epoch_ < bootstrapEpochs) {// 28 first epochs with 4.5% expansion
            _rate = bootstrapSupplyExpansionPercent * 100; // 1% = 1e16
        } else {
            uint256 _twap = getDarkgUpdatedPrice();
            if (_twap >= darkgPriceCeiling) {
                uint256 _percentage = _twap.sub(darkgPriceOne); // 1% = 1e16
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                _rate = _percentage.div(1e12);
            }
        }
    }

    function getNextExpansionAmount() external override view returns (uint256) {
        uint256 _rate = getNextExpansionRate();
        return getDarkgCirculatingSupply().mul(_rate).div(1e6);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _darkg,
        address _bond,
        address _darkgOracle,
        address _boardroom,
        uint256 _startTime
    ) public notInitialized {
        darkg = _darkg;
        bond = _bond;
        darkgOracle = _darkgOracle;
        boardroom = _boardroom;

        startTime = _startTime;
        epochLength_ = 4 hours;
        lastEpochTime = _startTime.sub(4 hours);

        darkgPriceOne = 10**18; // This is to allow a PEG of 1 DARKG per DARK
        darkgPriceCeiling = darkgPriceOne.mul(1001).div(1000);

        maxSupplyExpansionPercent = 200; // Upto 2.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn DARKG and mint LIGHTG)
        maxDebtRatioPercent = 4500; // Upto 45% supply of LIGHTG to purchase

        maxDiscountRate = 13e17; // 30% - when purchasing bond
        maxPremiumRate = 13e17; // 30% - when redeeming bond

        discountPercent = 0; // no discount
        premiumPercent = 6500; // 65% premium

        boardroomWithdrawFee = 500; // 5% when contraction

        // First 42 epochs with 3% expansion
        bootstrapEpochs = 42;
        bootstrapSupplyExpansionPercent = 300;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(darkg).balanceOf(address(this));

        nextSupplyTarget = 1000000 ether; // 1M supply is the next target to reduce expansion rate

        skygRewardPoolExpansionRate = 0.0009499924 ether; // 60000 skyg / (731 days * 24h * 60min * 60s)
        skygRewardPoolContractionRate = 0.0014249886 ether; // 1.5x

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function resetStartTime(uint256 _startTime) external onlyOperator {
        require(epoch_ == 0, "already started");
        startTime = _startTime;
        lastEpochTime = _startTime.sub(epochLength_);
    }

    function setEpochLength(uint256 _epochLength) external onlyOperator {
        require(_epochLength >= 1 hours && _epochLength <= 24 hours, "out of range");
        epochLength_ = _epochLength;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setBoardroomWithdrawFee(uint256 _boardroomWithdrawFee) external onlyOperator {
        require(_boardroomWithdrawFee <= 20, "Max withdraw fee is 20%");
        boardroomWithdrawFee = _boardroomWithdrawFee;
    }

    function setRegulationStats(address _regulationStats) external onlyOperator {
        regulationStats = _regulationStats;
    }

    function setSkygRewardPool(address _skygRewardPool) external onlyOperator {
        skygRewardPool = _skygRewardPool;
    }

    function setSkygRewardPoolRates(uint256 _skygRewardPoolExpansionRate, uint256 _skygRewardPoolContractionRate) external onlyOperator {
        require(_skygRewardPoolExpansionRate <= 0.5 ether && _skygRewardPoolExpansionRate <= 0.5 ether, "too high");
        require(_skygRewardPoolContractionRate >= 0.05 ether && _skygRewardPoolContractionRate >= 0.05 ether, "too low");
        skygRewardPoolExpansionRate = _skygRewardPoolExpansionRate;
        skygRewardPoolContractionRate = _skygRewardPoolContractionRate;
    }

    function setDarkgOracle(address _darkgOracle) external onlyOperator {
        darkgOracle = _darkgOracle;
    }

    function setDarkgPriceCeiling(uint256 _darkgPriceCeiling) external onlyOperator {
        require(_darkgPriceCeiling >= darkgPriceOne && _darkgPriceCeiling <= darkgPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        darkgPriceCeiling = _darkgPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setFundings(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _marketingFund,
        uint256 _marketingFundSharedPercent,
        address _insuranceFund,
        uint256 _insuranceFundSharedPercent
    ) external onlyOperator {
        require(_daoFundSharedPercent == 0 || _daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 4000, "out of range"); // <= 40%
        require(_marketingFundSharedPercent == 0 || _marketingFund != address(0), "zero");
        require(_marketingFundSharedPercent <= 2000, "out of range"); // <= 20%
        require(_insuranceFundSharedPercent == 0 || _insuranceFund != address(0), "zero");
        require(_insuranceFundSharedPercent <= 3000, "out of range"); // <= 30%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        marketingFund = _marketingFund;
        marketingFundSharedPercent = _marketingFundSharedPercent;
        insuranceFund = _insuranceFund;
        insuranceFundSharedPercent = _insuranceFundSharedPercent;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyOperator {
        require(_allocateSeigniorageSalary <= 10000 ether, "Treasury: dont pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function setNextSupplyTarget(uint256 _target) external onlyOperator {
        require(_target > IERC20(darkg).totalSupply(), "too small");
        nextSupplyTarget = _target;
    }

    function setDarkgLockedAccounts(address[] memory _darkgLockedAccounts) external onlyOperator {
        delete darkgLockedAccounts;
        uint256 _length = _darkgLockedAccounts.length;
        for (uint256 i = 0; i < _length; i++) {
            darkgLockedAccounts.push(_darkgLockedAccounts[i]);
        }
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateDarkgPrice() internal {
        try IOracle(darkgOracle).update() {} catch {}
    }

    function buyBonds(uint256 _darkgAmount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_darkgAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 darkgPrice = getDarkgPrice();
        require(darkgPrice == targetPrice, "Treasury: DARKG price moved");
        require(
            darkgPrice < darkgPriceOne, // price < $1
            "Treasury: darkgPrice not eligible for bond purchase"
        );

        require(_darkgAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        address _darkg = darkg;
        uint256 _bondAmount = _darkgAmount.mul(_rate).div(1e18);
        uint256 _darkgSupply = IERC20(darkg).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= _darkgSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(_darkg).burnFrom(msg.sender, _darkgAmount);
        IBasisAsset(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_darkgAmount);
        _updateDarkgPrice();
        if (regulationStats != address(0)) IRegulationStats(regulationStats).addBonded(epoch_, _bondAmount);

        emit BoughtBonds(msg.sender, _darkgAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 darkgPrice = getDarkgPrice();
        require(darkgPrice == targetPrice, "Treasury: DARKG price moved");
        require(
            darkgPrice > darkgPriceCeiling, // price > $1.01
            "Treasury: darkgPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _darkgAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(darkg).balanceOf(address(this)) >= _darkgAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _darkgAmount));
        allocateSeigniorageSalary = 1 ether; // 1 DARKG salary for calling allocateSeigniorage()

        IBasisAsset(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(darkg).safeTransfer(msg.sender, _darkgAmount);

        _updateDarkgPrice();
        if (regulationStats != address(0)) IRegulationStats(regulationStats).addRedeemed(epoch_, _darkgAmount);

        emit RedeemedBonds(msg.sender, _darkgAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount, uint256 _expanded) internal {
        address _darkg = darkg;
        IBasisAsset(_darkg).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(_darkg).transfer(daoFund, _daoFundSharedAmount);
        }

        uint256 _marketingFundSharedAmount = 0;
        if (marketingFundSharedPercent > 0) {
            _marketingFundSharedAmount = _amount.mul(marketingFundSharedPercent).div(10000);
            IERC20(_darkg).transfer(marketingFund, _marketingFundSharedAmount);
        }

        uint256 _insuranceFundSharedAmount = 0;
        if (insuranceFundSharedPercent > 0) {
            _insuranceFundSharedAmount = _amount.mul(insuranceFundSharedPercent).div(10000);
            IERC20(_darkg).transfer(insuranceFund, _insuranceFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_marketingFundSharedAmount).sub(_insuranceFundSharedAmount);

        IERC20(_darkg).safeIncreaseAllowance(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);

        if (regulationStats != address(0)) IRegulationStats(regulationStats).addEpochInfo(epoch_.add(1), previousEpochDarkgPrice, _expanded,
            _amount, _daoFundSharedAmount, _marketingFundSharedAmount, _insuranceFundSharedAmount);
        emit FundingAdded(epoch_, block.timestamp, previousEpochDarkgPrice, _expanded,
            _amount, _daoFundSharedAmount, _marketingFundSharedAmount, _insuranceFundSharedAmount);
    }

    function allocateSeigniorage() external onlyOneBlock checkEpoch checkOperator nonReentrant {
        _updateDarkgPrice();
        previousEpochDarkgPrice = getDarkgPrice();
        address _darkg = darkg;
        uint256 _supply = getDarkgCirculatingSupply();
        uint256 _nextSupplyTarget = nextSupplyTarget;
        if (_supply >= _nextSupplyTarget) {
            nextSupplyTarget = _nextSupplyTarget.mul(12500).div(10000); // +25%
            maxSupplyExpansionPercent = maxSupplyExpansionPercent.mul(9500).div(10000); // -5%
            if (maxSupplyExpansionPercent < 25) {
                maxSupplyExpansionPercent = 25; // min 0.25%
            }
        }
        uint256 _seigniorage;
        if (epoch_ < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _seigniorage = _supply.mul(bootstrapSupplyExpansionPercent).div(10000);
            _sendToBoardroom(_seigniorage, _seigniorage);
        } else {
            address _skygRewardPool = skygRewardPool;
            if (previousEpochDarkgPrice > darkgPriceCeiling) {
                IBoardroom(boardroom).setWithdrawFee(0);
                // Expansion ($DARKG Price > 1 $CRO): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                uint256 _percentage = previousEpochDarkgPrice.sub(darkgPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = _seigniorage = _supply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    _seigniorage = _supply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom, _seigniorage);
                } else {
                    // function addEpochInfo(uint256 epochNumber, uint256 twap, uint256 expanded, uint256 boardroomFunding, uint256 daoFunding, uint256 marketingFunding, uint256 insuranceFunding) external;
                    if (regulationStats != address(0)) IRegulationStats(regulationStats).addEpochInfo(epoch_.add(1), previousEpochDarkgPrice, 0, 0, 0, 0, 0);
                    emit FundingAdded(epoch_.add(1), block.timestamp, previousEpochDarkgPrice, 0, 0, 0, 0, 0);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(_darkg).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
                if (_skygRewardPool != address(0) && IRewardPool(_skygRewardPool).getRewardPerSecond() != skygRewardPoolExpansionRate) {
                    IRewardPool(_skygRewardPool).updateRewardRate(skygRewardPoolExpansionRate);
                }
            } else if (previousEpochDarkgPrice < darkgPriceOne) {
                IBoardroom(boardroom).setWithdrawFee(boardroomWithdrawFee);
                if (_skygRewardPool != address(0) && IRewardPool(_skygRewardPool).getRewardPerSecond() != skygRewardPoolContractionRate) {
                    IRewardPool(_skygRewardPool).updateRewardRate(skygRewardPoolContractionRate);
                }
                if (regulationStats != address(0)) IRegulationStats(regulationStats).addEpochInfo(epoch_.add(1), previousEpochDarkgPrice, 0, 0, 0, 0, 0);
                emit FundingAdded(epoch_.add(1), block.timestamp, previousEpochDarkgPrice, 0, 0, 0, 0, 0);
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(_darkg).mint(address(msg.sender), allocateSeigniorageSalary);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(darkg), "darkg");
        require(address(_token) != address(bond), "bond");
        _token.safeTransfer(_to, _amount);
    }

    function tokenTransferOperator(address _token, address _operator) external onlyOperator {
        IBasisAsset(_token).transferOperator(_operator);
    }

    function tokenTransferOwnership(address _token, address _operator) external onlyOperator {
        IBasisAsset(_token).transferOwnership(_operator);
    }

    function boardroomGovernanceRecoverUnsupported(address _boardRoomOrToken, address _token, uint256 _amount, address _to) external onlyOperator {
        IBoardroom(_boardRoomOrToken).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
