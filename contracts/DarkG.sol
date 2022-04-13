// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./owner/Operator.sol";
import "./interfaces/IOracle.sol";

// DARKGANG FINANCE
contract DarkG is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // Supply used to launch in LP
    uint256 public constant INITIAL_LAUNCH_DISTRIBUTION = 500000 ether; // 0.5 million of DARKG

    // Have the rewards been distributed to the pools
    bool public rewardPoolDistributed = false;

    uint256 private totalBurned_;

    /**
     * @notice Constructs the DARKG ERC-20 contract.
     */
    constructor() public ERC20("DarkGang", "DARKG") {
        _mint(msg.sender, 10000 ether); // for initial liquidity deployment
    }

    /**
     * @notice Operator mints DARKG to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of DARKG to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _launcherAddress
    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_launcherAddress != address(0), "!_launcherAddress");
        rewardPoolDistributed = true;
        _mint(_launcherAddress, INITIAL_LAUNCH_DISTRIBUTION);
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
