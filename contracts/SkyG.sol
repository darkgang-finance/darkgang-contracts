// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "./owner/Operator.sol";

// DARKGANG FINANCE
contract SkyG is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 100,000 SkyG
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 60000 ether;
    uint256 public constant DAO_FUND_POOL_ALLOCATION = 15000 ether;
    uint256 public constant INSURANCE_FUND_POOL_ALLOCATION = 12500 ether;
    uint256 public constant DEV_FUND_POOL_ALLOCATION = 12000 ether;

    uint256 public constant VESTING_DURATION = 731 days; // 2 years
    uint256 public startTime;
    uint256 public endTime;

    uint256 public daoFundRewardRate;
    uint256 public insuranceFundRewardRate;
    uint256 public devFundRewardRate;

    address public insuranceFund;
    address public daoFund;
    address public devFund;

    uint256 public lastClaimedTime;

    bool public rewardPoolDistributed = false;

    uint256 private totalBurned_;

    constructor(uint256 _startTime, address _daoFund, address _devFund, address _insuranceFund) public ERC20("DarkGang Share", "SKYG") {
        _mint(msg.sender, 500 ether); // mint 500 SKYG for initial liquidity deployment

        startTime = _startTime; // supposed to be 1648044000 (Wednesday, 23 March 2022, 14:00:00 UTC)
        endTime = startTime + VESTING_DURATION; // (Saturday, 23 March 2024 14:00:00 UTC)

        lastClaimedTime = startTime;

        daoFundRewardRate = DAO_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        insuranceFundRewardRate = INSURANCE_FUND_POOL_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;

        require(_insuranceFund != address(0), "Address cannot be 0");
        insuranceFund = _insuranceFund;
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function setInsuranceFund(address _insuranceFund) external onlyOperator {
        require(_insuranceFund != address(0), "zero");
        insuranceFund = _insuranceFund;
    }

    function setDevFund(address _devFund) external onlyOperator {
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedDaoFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(daoFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(devFundRewardRate);
    }

    function unclaimedInsuranceFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(insuranceFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedDaoFund();
        if (_pending > 0 && daoFund != address(0)) {
            _mint(daoFund, _pending);
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
        }
        _pending = unclaimedInsuranceFund();
        if (_pending > 0 && insuranceFund != address(0)) {
            _mint(insuranceFund, _pending);
        }
        lastClaimedTime = block.timestamp;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function totalBurned() external view returns (uint256) {
        return totalBurned_;
    }

    function _burn(address _account, uint256 _amount) internal override {
        super._burn(_account, _amount);
        totalBurned_ = totalBurned_.add(_amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
