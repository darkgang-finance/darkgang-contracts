// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./utils/ShareWrapper.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";

// DARKGANG FINANCE
contract Boardroom is ShareWrapper, OwnableUpgradeSafe, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Memberseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardroomSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 public darkg;
    ITreasury public treasury;

    mapping(address => Memberseat) public members;
    BoardroomSnapshot[] public boardroomHistory;

    uint256 public withdrawLockupEpochs;

    address public reserveFund;
    uint256 public withdrawFee;
    uint256 public stakeFee;

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount, uint256 fee);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
    event RewardSacrificed(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOwnerOrTreasury() {
        require(address(treasury) == msg.sender || owner() == msg.sender, "Boardroom: caller is not the operator");
        _;
    }

    modifier memberExists() {
        require(balanceOf(msg.sender) > 0, "Boardroom: The member does not exist");
        _;
    }

    modifier updateReward(address member) {
        if (member != address(0)) {
            Memberseat memory seat = members[member];
            seat.rewardEarned = earned(member);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            members[member] = seat;
        }
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _darkg,
        IERC20 _share,
        ITreasury _treasury,
        address _reserveFund
    ) external initializer {
        OwnableUpgradeSafe.__Ownable_init();

        darkg = _darkg;
        share = _share;
        treasury = _treasury;
        reserveFund = _reserveFund;

        BoardroomSnapshot memory genesisSnapshot = BoardroomSnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0});
        boardroomHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 12; // Lock for 12 epochs (72h) before release withdraw
        withdrawFee = 0;
        stakeFee = 200;
    }

    function setLockUp(uint256 _withdrawLockupEpochs) external onlyOwner {
        require(_withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
    }

    function setReserveFund(address _reserveFund) external onlyOwner {
        require(_reserveFund != address(0), "reserveFund address cannot be 0 address");
        reserveFund = _reserveFund;
    }

    function setStakeFee(uint256 _stakeFee) external onlyOwnerOrTreasury {
        require(_stakeFee <= 500, "Max stake fee is 5%");
        stakeFee = _stakeFee;
    }

    function setWithdrawFee(uint256 _withdrawFee) external onlyOwnerOrTreasury {
        require(_withdrawFee <= 2000, "Max withdraw fee is 20%");
        withdrawFee = _withdrawFee;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardroomHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address member) public view returns (uint256) {
        return members[member].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address member) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[getLastSnapshotIndexOf(member)];
    }

    function canClaimReward() public view returns (bool) {
        ITreasury _treasury = ITreasury(treasury);
        return _treasury.previousEpochDarkgPrice() >= 1e18 && _treasury.getNextExpansionRate() > 0; // current epoch and next epoch are both expansion
    }

    function canWithdraw(address member) external view returns (bool) {
        return members[member].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getDarkgPrice() external view returns (uint256) {
        return treasury.getDarkgPrice();
    }

    // =========== Member getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address member) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(member).rewardPerShare;

        return balanceOf(member).mul(latestRPS.sub(storedRPS)).div(1e18).add(members[member].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 _amount) external onlyOneBlock updateReward(msg.sender) {
        require(_amount > 0, "Boardroom: Cannot stake 0");
        if (members[msg.sender].rewardEarned > 0) {
            claimReward();
        }
        uint256 _fee = 0;
        uint256 _stakeFee = stakeFee;
        if (_stakeFee > 0) {
            _fee = _amount.mul(_stakeFee).div(10000);
            _amount = _amount.sub(_fee);
        }
        super._stake(_amount);
        if (_fee > 0) {
            share.safeTransferFrom(msg.sender, reserveFund, _fee);
        }
        members[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, _amount, _fee);
    }

    function withdraw(uint256 _amount) public onlyOneBlock memberExists updateReward(msg.sender) {
        require(_amount > 0, "Boardroom: Cannot withdraw 0");
        require(members[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        _sacrificeReward();
        uint256 _fee = 0;
        uint256 _withdrawFee = withdrawFee;
        uint256 _transferAmount = _amount;
        if (_withdrawFee > 0) {
            _fee = _amount.mul(_withdrawFee).div(10000);
            share.safeTransfer(reserveFund, _fee);
            _transferAmount = _amount.sub(_fee);
        }
        super._withdraw(_amount, _transferAmount);
        emit Withdrawn(msg.sender, _amount, _fee);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function _sacrificeReward() internal updateReward(msg.sender) {
        uint256 reward = members[msg.sender].rewardEarned;
        if (reward > 0) {
            members[msg.sender].rewardEarned = 0;
            IBasisAsset(address(darkg)).burn(reward);
            emit RewardSacrificed(msg.sender, reward);
        }
    }

    function claimReward() public updateReward(msg.sender) {
        require(canClaimReward(), "contraction");
        uint256 reward = members[msg.sender].rewardEarned;
        if (reward > 0) {
            members[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            members[msg.sender].rewardEarned = 0;
            darkg.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOwnerOrTreasury {
        require(amount > 0, "Boardroom: Cannot allocate 0");
        require(totalSupply() > 0, "Boardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardroomSnapshot memory newSnapshot = BoardroomSnapshot({time: block.number, rewardReceived: amount, rewardPerShare: nextRPS});
        boardroomHistory.push(newSnapshot);

        darkg.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        // do not allow to drain core tokens
        require(address(_token) != address(darkg), "darkg");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
