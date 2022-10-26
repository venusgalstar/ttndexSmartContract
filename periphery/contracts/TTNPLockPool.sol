// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./utils/SafeERC20.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/Pausable.sol";
import "./interfaces/IMasterChef.sol";
import "./TTNDEXReferral.sol";

// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Main is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract TTNPLockPool is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lockEndTime; // lock end time.

        // We do some fancy math here. Basically, any point in time, the amount of Tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws tokens to a pool. Here's what happens:
        //   1. The pool's `accTokenPerShare` gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 amount;
        uint256 accTokenPerShare; // Accumulated Tokens per share, times 1e12. See below.
    }

    uint256 public constant MIN_LOCK_TIME = 1 weeks; // 1 week
    uint256 public constant MAX_LOCK_TIME = 1000 days; // 1000 days

    IMasterChef public immutable masterchef;
    uint256 public immutable ttnpLockPoolPID;
    // The Main TOKEN
    IERC20 public immutable ttnp;

    // Info of pool.
    PoolInfo public poolInfo;
    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    // TTNDEXReferral contract address.
    TTNDEXReferral public immutable referral;
    // TTNDEXReferral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 20%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 2000;
    uint16 public constant DENOMINATOR = 10000;

    event Deposit(address indexed user, uint256 amount, uint256 lockEndTime);
    event Withdraw(address indexed user, uint256 amount, uint256 lockEndTime);
    event Harvest(address indexed user, uint256 amount);
    event ReferralCommissionWithdrawn(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );

    /**
     * @notice Deposits a dummy token to `MASTER_CHEF`.
     * It will transfer all the `_dummyToken` in the tx sender address.
     * @param _ttnp Main token contract address
     * @param _masterchef MasterChef address
     * @param _pid Pid value of TTNPFlexiblePool in MasterChef
     * @param _referral TTNDEXReferral Address
     * @param _dummyToken The address of the token to be deposited into MC.
     */
    constructor(
        IERC20 _ttnp,
        IMasterChef _masterchef,
        uint256 _pid,
        address _referral,
        IERC20 _dummyToken
    ) {
        ttnp = _ttnp;
        masterchef = _masterchef;
        ttnpLockPoolPID = _pid;

        referral = TTNDEXReferral(_referral);

        uint256 balance = _dummyToken.balanceOf(msg.sender);
        require(balance != 0, "Balance must exceed 0");
        _dummyToken.safeTransferFrom(msg.sender, address(this), balance);
        _dummyToken.approve(address(_masterchef), balance);
        _masterchef.deposit(_pid, balance, address(0));

        poolInfo = PoolInfo({amount: 0, accTokenPerShare: 0});
    }

    // View function to see pending Tokens
    function pendingTTNP(address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 pendingReward = masterchef.pendingTTNP(
            ttnpLockPoolPID,
            address(this)
        );

        if (pendingReward > 0 && pool.amount != 0) {
            uint256 tokenReward = (pendingReward * DENOMINATOR) /
                (DENOMINATOR + referralCommissionRate);
            accTokenPerShare =
                accTokenPerShare +
                ((tokenReward * 1e12) / pool.amount);
        }

        uint256 pending = (user.amount * accTokenPerShare) /
            1e12 -
            user.rewardDebt;
        return pending;
    }

    /**
     * @notice Harvest pending TTNP tokens from MasterChef
     */
    function harvest() internal returns (uint256 harvestAmount) {
        uint256 pendingReward = masterchef.pendingTTNP(
            ttnpLockPoolPID,
            address(this)
        );
        if (pendingReward > 0) {
            uint256 balBefore = ttnp.balanceOf(address(this));
            masterchef.withdraw(ttnpLockPoolPID, 0);
            uint256 balAfter = ttnp.balanceOf(address(this));
            harvestAmount = balAfter - balBefore;
            emit Harvest(msg.sender, harvestAmount);
        }
    }

    // Update reward variables to be up-to-date.
    function updatePool() public {
        uint256 harvestAmount = harvest();
        if (harvestAmount <= 0) {
            return;
        }

        PoolInfo storage pool = poolInfo;
        if (pool.amount == 0) {
            ttnp.transfer(owner(), harvestAmount);
            return;
        }

        uint256 tokenReward = (harvestAmount * DENOMINATOR) /
            (DENOMINATOR + referralCommissionRate);
        pool.accTokenPerShare =
            pool.accTokenPerShare +
            ((tokenReward * 1e12) / pool.amount);
    }

    // Deposit tokens to StakingVault for Main allocation.
    function deposit(uint256 _amount, uint256 _lockTime, address _referrer) external nonReentrant whenNotPaused {
        require(_lockTime >= MIN_LOCK_TIME, "Minimum lock period is one week");
        require(_lockTime <= MAX_LOCK_TIME, "Maximum lock period exceeded");
        
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (
            _amount > 0 &&
            address(referral) != address(0) &&
            _referrer != address(0) &&
            _referrer != msg.sender
        ) {
            referral.recordReferral(msg.sender, _referrer);
        }
        withdrawPendingReward();
        if (_amount > 0) {
            ttnp.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount + _amount;
            pool.amount = pool.amount + _amount;
            
            uint256 newLockEndTime = block.timestamp + _lockTime;
            if(newLockEndTime > user.lockEndTime) {
                user.lockEndTime = newLockEndTime;
            }
        }
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Deposit(msg.sender, _amount, user.lockEndTime);
    }

    // Withdraw tokens from StakingVault.
    function withdraw(uint256 _amount, uint256 _lockTime) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool();
        withdrawPendingReward();
        if (_amount > 0) {
            require(user.lockEndTime < block.timestamp, "Still in lock");

            user.amount = user.amount - _amount;
            pool.amount = pool.amount - _amount;

            if(user.amount > 0) {
                require(_lockTime >= MIN_LOCK_TIME, "Minimum lock period is one week");
                user.lockEndTime = block.timestamp + _lockTime;
            }
            ttnp.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Withdraw(msg.sender, _amount, user.lockEndTime);
    }

    function withdrawPendingReward() internal {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];

        uint256 pending = (user.amount * pool.accTokenPerShare) /
            1e12 -
            user.rewardDebt;
        if (pending > 0) {
            // send rewards
            ttnp.safeTransfer(msg.sender, pending);
            withdrawReferralCommission(msg.sender, pending);
        }
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        external
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    // Withdraw referral commission to the referrer who referred this user.
    function withdrawReferralCommission(address _user, uint256 _pending)
        internal
    {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = (_pending * referralCommissionRate) /
                DENOMINATOR;

            if (referrer != address(0) && commissionAmount > 0) {
                ttnp.safeTransfer(address(referral), commissionAmount);
                referral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionWithdrawn(
                    _user,
                    referrer,
                    commissionAmount
                );
            }
        }
    }
}
