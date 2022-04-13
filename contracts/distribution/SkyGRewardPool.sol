// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IRewardPool.sol";
import "../interfaces/IBasisAsset.sol";
import "../interfaces/INFTController.sol";

contract SkygRewardPool is IRewardPool, OwnableUpgradeSafe, IERC721Receiver, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken;           // Address of LP token contract.
        uint256 allocPoint;        // How many allocation points assigned to this pool. SKYG to distribute per block.
        uint256 lastRewardTime;    // Last block number that SKYG distribution occurs.
        uint256 accSkyGPerShare;  // Accumulated SKYG per share, times 1e18. See below.
        uint16 depositFeeBP;       // Deposit fee in basis points
        uint256 lockedTime;
        bool isStarted;            // if lastRewardTime has passed
    }

    struct NFTSlot {
        address slot1;
        uint256 tokenId1;
        address slot2;
        uint256 tokenId2;
        address slot3;
        uint256 tokenId3;
    }

    // The SKYG TOKEN!
    address public skyg;

    address public insuranceFund;
    uint256 public totalSkyGTaxed;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 private totalAllocPoint_;

    // The time when SkyG mining starts.
    uint256 public poolStartTime;

    // The time when SkyG mining ends.
    uint256 public poolEndTime;
    uint256 public lastTimeUpdateRewardRate;
    uint256 public accumulatedRewardPaid;

    uint256 public rewardPerSecond;
    uint256 public constant DEFAULT_RUNNING_TIME = 731 days;
    uint256 public constant TOTAL_REWARDS = 60000 ether;

    address public treasury;
    address public nftController;

    mapping(address => bool) public poolExistence;
    mapping(address => mapping(uint256 => NFTSlot)) private _depositedNFT; // user => pid => nft slot;

    bool public whitelistAll;
    mapping(address => bool) public whitelist_;

    uint256 public nftBoostRate;

    mapping(uint256 => mapping(address => uint256)) public userLastDepositTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 indexed pid, uint256 amount, uint256 boost);
    event RewardTaxed(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateRewardPerSecond(uint256 rewardPerSecond);
    event UpdateNFTController(address indexed user, address controller);
    event UpdateTreasury(address indexed user, address treasury);
    event UpdateInsuranceFund(address indexed user, address insuranceFund);
    event UpdateNFTBoostRate(address indexed user, uint256 controller);
    event Whitelisted(address indexed account, bool on);
    event OnERC721Received(address operator, address from, uint256 tokenId, bytes data);

    function initialize(
        address _skyg,
        address _insuranceFund,
        uint256 _poolStartTime
    ) external initializer {
        OwnableUpgradeSafe.__Ownable_init();

        skyg = _skyg;

        insuranceFund = _insuranceFund;
        totalSkyGTaxed = 0;

        poolStartTime = _poolStartTime; // supposed to be 1648220400 (Friday, 25 March 2022 15:00:00 GMT)
        poolEndTime = poolStartTime.add(DEFAULT_RUNNING_TIME);
        rewardPerSecond = TOTAL_REWARDS.div(DEFAULT_RUNNING_TIME); // =0.0009499924000607996 SKYG/sec = 60000 SKYG / (731 days * 24h * 60min * 60sec)
        lastTimeUpdateRewardRate = _poolStartTime;
        accumulatedRewardPaid = 0;

        totalAllocPoint_ = 0;
        whitelistAll = true;
        nftBoostRate = 10000;
    }

    /* ========== Modifiers ========== */

    modifier nonDuplicated(address _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    modifier checkContract() {
        if (!whitelistAll && !whitelist_[msg.sender]) {
            require(tx.origin == msg.sender, "contract");
        }
        _;
    }

    modifier onlyOwnerOrTreasury() {
        require(msg.sender == treasury || msg.sender == owner(), "!treasury nor owner");
        _;
    }

    /* ========== NFT View Functions ========== */

    function getBoost(address _account, uint256 _pid) public view returns (uint256) {
        INFTController _controller = INFTController(nftController);
        if (address(_controller) == address(0)) return 0;
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        uint256 boost1 = _controller.getBoostRate(slot.slot1, slot.tokenId1);
        uint256 boost2 = _controller.getBoostRate(slot.slot2, slot.tokenId2);
        uint256 boost3 = _controller.getBoostRate(slot.slot3, slot.tokenId3);
        uint256 boost = boost1 + boost2 + boost3;
        return boost.mul(nftBoostRate).div(10000); // boosts from 0% onwards
    }

    function getSlots(address _account, uint256 _pid) public view returns (address, address, address) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.slot1, slot.slot2, slot.slot3);
    }

    function getTokenIds(address _account, uint256 _pid) public view returns (uint256, uint256, uint256) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.tokenId1, slot.tokenId2, slot.tokenId3);
    }

    /* ========== View Functions ========== */

    function reward() external override view returns (address) {
        return skyg;
    }

    function totalAllocPoint() external override view returns (uint256) {
        return totalAllocPoint_;
    }

    function poolLength() external override view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint256 _pid) external override view returns (address _lp, uint256 _allocPoint) {
        PoolInfo memory pool = poolInfo[_pid];
        _lp = address(pool.lpToken);
        _allocPoint = pool.allocPoint;
    }

    function getRewardPerSecond() external override view returns (uint256) {
        return rewardPerSecond;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(rewardPerSecond);
            return poolEndTime.sub(_fromTime).mul(rewardPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(rewardPerSecond);
            return _toTime.sub(_fromTime).mul(rewardPerSecond);
        }
    }

    // View function to see pending SkyGs on frontend.
    function pendingReward(uint256 _pid, address _user) public override view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSkyGPerShare = pool.accSkyGPerShare;
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _skygReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            accSkyGPerShare = accSkyGPerShare.add(_skygReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accSkyGPerShare).div(1e18).sub(user.rewardDebt);
    }

    function pendingAllRewards(address _user) external override view returns (uint256 _total) {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _total = _total.add(pendingReward(pid, _user));
        }
    }

    /* ========== Owner Functions ========== */

    // Add a new lp to the pool. Can only be called by the owner.
    function addPool(uint256 _allocPoint, address _lpToken, uint16 _depositFeeBP, uint256 _lastRewardTime, uint256 _lockedTime) public onlyOwner nonDuplicated(_lpToken) {
        require(_allocPoint <= 100000, "too high allocation point"); // <= 100x
        require(_depositFeeBP <= 1000, "too high fee"); // <= 10%
        require(_lockedTime <= 30 days, "locked time is too long");
        massUpdatePools();
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        poolExistence[_lpToken] = true;
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accSkyGPerShare : 0,
            depositFeeBP : _depositFeeBP,
            lockedTime : _lockedTime,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint_ = totalAllocPoint_.add(_allocPoint);
        }
    }

    // Update the given pool's SKYG allocation point and deposit fee. Can only be called by the owner.
    function setPool(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _lockedTime) public onlyOwner {
        require(_allocPoint <= 100000, "too high allocation point"); // <= 100x
        require(_depositFeeBP <= 1000, "too high fee"); // <= 10%
        require(_lockedTime <= 30 days, "locked time is too long");
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint_ = totalAllocPoint_.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;
        pool.lockedTime = _lockedTime;
    }

    /* ========== NFT External Functions ========== */

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {
        require(INFTController(nftController).isWhitelistedNFT(msg.sender), "only approved NFTs");
        emit OnERC721Received(operator, from, tokenId, data);
        return this.onERC721Received.selector;
    }

    // Depositing of NFTs
    function depositNFT(address _nft, uint256 _tokenId, uint256 _slot, uint256 _pid) external nonReentrant checkContract {
        require(INFTController(nftController).isWhitelistedNFT(_nft), "only approved NFTs");
        require(IERC721(_nft).ownerOf(_tokenId) != msg.sender, "user does not have specified NFT");
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount == 0, "not allowed to deposit");

        updatePool(_pid);
        _harvestReward(_pid, msg.sender, false);
        user.rewardDebt = user.amount.mul(poolInfo[_pid].accSkyGPerShare).div(1e18);

        IERC721(_nft).transferFrom(msg.sender, address(this), _tokenId);

        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) slot.slot1 = _nft;
        else if (_slot == 2) slot.slot2 = _nft;
        else if (_slot == 3) slot.slot3 = _nft;

        if (_slot == 1) slot.tokenId1 = _tokenId;
        else if (_slot == 2) slot.tokenId2 = _tokenId;
        else if (_slot == 3) slot.tokenId3 = _tokenId;

        _depositedNFT[msg.sender][_pid] = slot;
    }

    // Withdrawing of NFTs
    function withdrawNFT(uint256 _slot, uint256 _pid) external nonReentrant checkContract {
        updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount > 0) {
            _harvestReward(_pid, msg.sender, false);
        }
        user.rewardDebt = user.amount.mul(poolInfo[_pid].accSkyGPerShare).div(1e18);

        address _nft;
        uint256 _tokenId;

        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) _nft = slot.slot1;
        else if (_slot == 2) _nft = slot.slot2;
        else if (_slot == 3) _nft = slot.slot3;

        if (_slot == 1) _tokenId = slot.tokenId1;
        else if (_slot == 2) _tokenId = slot.tokenId2;
        else if (_slot == 3) _tokenId = slot.tokenId3;

        if (_slot == 1) slot.slot1 = address(0);
        else if (_slot == 2) slot.slot2 = address(0);
        else if (_slot == 3) slot.slot3 = address(0);

        if (_slot == 1) slot.tokenId1 = uint256(0);
        else if (_slot == 2) slot.tokenId2 = uint256(0);
        else if (_slot == 3) slot.tokenId3 = uint256(0);

        _depositedNFT[msg.sender][_pid] = slot;

        IERC721(_nft).transferFrom(address(this), msg.sender, _tokenId);
    }

    /* ========== External Functions ========== */

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint_ = totalAllocPoint_.add(pool.allocPoint);
        }
        if (totalAllocPoint_ > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _skygReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            pool.accSkyGPerShare = pool.accSkyGPerShare.add(_skygReward.mul(1e18).div(lpSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    function _harvestReward(uint256 _pid, address _account, bool _taxedReward) internal {
        UserInfo memory user = userInfo[_pid][_account];
        PoolInfo memory pool = poolInfo[_pid];
        uint256 _pending = user.amount.mul(pool.accSkyGPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            if (_taxedReward) {
                uint256 _boost = _pending.mul(getBoost(_account, _pid)).div(10000);
                uint256 _half_boosted_pending = _pending.add(_boost).div(2);
                _safeSkyGTransfer(_account, _half_boosted_pending);
                emit RewardPaid(_account, _pid, _pending, _boost);
                _safeSkyGTransfer(_account, _half_boosted_pending);
                totalSkyGTaxed = totalSkyGTaxed.add(_half_boosted_pending);
                emit RewardTaxed(_account, _pid, _half_boosted_pending);
            } else {
                uint256 _boost = _pending.mul(getBoost(_account, _pid)).div(10000);
                _safeSkyGTransfer(_account, _pending.add(_boost));
                emit RewardPaid(_account, _pid, _pending, _boost);
            }
            userLastDepositTime[_pid][_account] = block.timestamp;
        }
    }

    // Deposit LP tokens to MasterChef for SKYG allocation.
    function deposit(uint256 _pid, uint256 _amount) external override nonReentrant checkContract {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            _harvestReward(_pid, msg.sender, false);
        }
        if (_amount > 0) {
            IERC20 _lpToken = IERC20(pool.lpToken);
            uint256 _before = _lpToken.balanceOf(address(this));
            _lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 _after = _lpToken.balanceOf(address(this));
            _amount = _after.sub(_before); // fix issue of deflation token
            if (_amount > 0) {
                user.amount = user.amount.add(_amount);
                userLastDepositTime[_pid][msg.sender] = block.timestamp;
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSkyGPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function unfrozenDepositTime(uint256 _pid, address _account) public view returns (uint256) {
        return (whitelist_[_account]) ? userLastDepositTime[_pid][_account] : userLastDepositTime[_pid][_account].add(poolInfo[_pid].lockedTime);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external override nonReentrant checkContract {
        _withdraw(msg.sender, _pid, _amount);
    }

    function _withdraw(address _account, uint256 _pid, uint256 _amount) internal {
        require(_amount == 0 || block.timestamp >= unfrozenDepositTime(_pid, _account), "still locked");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        if (user.amount > 0) {
            _harvestReward(_pid, _account, _amount > 0 && pool.lockedTime > 0);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            IERC20(pool.lpToken).safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSkyGPerShare).div(1e18);
        emit Withdraw(_account, _pid, _amount);
    }

    function withdrawAll(uint256 _pid) external override {
        _withdraw(msg.sender, _pid, userInfo[_pid][msg.sender].amount);
    }

    function harvestAllRewards() external override {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                _withdraw(msg.sender, pid, 0);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        IERC20(pool.lpToken).safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe SKYG transfer function, just in case if rounding error causes pool to not have enough SKYG.
    function _safeSkyGTransfer(address _to, uint256 _amount) internal {
        IERC20 _skyg = IERC20(skyg);
        uint256 _bal = _skyg.balanceOf(address(this));
        if (_amount > _bal) _amount = _bal;
        if (_amount > 0) {
            _skyg.transfer(_to, _amount);
        }
    }

    function updateRewardRate(uint256 _newRate) external override onlyOwnerOrTreasury {
        require(_newRate <= 0.01 ether, "too high");
        uint256 _oldRate = rewardPerSecond;
        massUpdatePools();
        if (block.timestamp > lastTimeUpdateRewardRate) {
            accumulatedRewardPaid = accumulatedRewardPaid.add(block.timestamp.sub(lastTimeUpdateRewardRate).mul(_oldRate));
            lastTimeUpdateRewardRate = block.timestamp;
        }
        if (accumulatedRewardPaid >= TOTAL_REWARDS) {
            poolEndTime = now;
            rewardPerSecond = 0;
        } else {
            rewardPerSecond = _newRate;
            uint256 _secondLeft = TOTAL_REWARDS.sub(accumulatedRewardPaid).div(_newRate);
            poolEndTime = (block.timestamp > poolStartTime) ? block.timestamp.add(_secondLeft) : poolStartTime.add(_secondLeft);
        }
    }

    function setWhitelist(address _address, bool _on) external onlyOwner {
        whitelist_[_address] = _on;
        emit Whitelisted(_address, _on);
    }

    function setNftController(address _controller) external onlyOwner {
        nftController = _controller;
        emit UpdateNFTController(msg.sender, _controller);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit UpdateTreasury(msg.sender, _treasury);
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        insuranceFund = _insuranceFund;
        emit UpdateInsuranceFund(msg.sender, _insuranceFund);
    }

    function setNftBoostRate(uint256 _rate) external onlyOwner {
        require(_rate >= 5000 && _rate <= 50000, "boost must be within range"); // 0.5x -> 5x
        nftBoostRate = _rate;
        emit UpdateNFTBoostRate(msg.sender, _rate);
    }

    function governanceRecoverUnsupported(address _token, uint256 amount, address to) external onlyOwner {
        if (block.timestamp < poolEndTime + 180 days) {
            // do not allow to drain core token (SkyG or lps) if less than 180 days after pool ends
            require(_token != skyg, "skyg");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "pool.token");
            }
        }
        IERC20(_token).safeTransfer(to, amount);
    }
}
