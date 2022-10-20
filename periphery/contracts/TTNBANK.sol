// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./interfaces/IERC20.sol";
import "./utils/Ownable.sol";
import "./utils/Pausable.sol";
import "./utils/ReentrancyGuard.sol";

contract TTNBANK is Ownable, Pausable, ReentrancyGuard {
    struct UserInfo {
        uint256 requestAmount; // staker => requestAmount
        uint256 requestEpochNumber; // staker => requestEpochNumber
        uint256 pendingClaimEpochNumber; // staker => pendingClaimEpochNumber
        uint256 lastActionEpochNumber; // staker => lastActionEpochNumber
        uint256 lastRewards; // staker => lastReward
        uint256 totalRewards; // staker => totalReward
        address referrals; // staker => referral
    }

    uint256 public constant MIN_APY = 1; // for only test
    uint256 public constant MAX_APY = 10**6; // for only test

    uint256 public constant REFERRAL_PERCENT = 1000; // 10%
    uint256 public constant WITHDRAW_FEE = 100; // 1%
    uint256 public constant DEV_FEE = 1000; // 10%

    uint256 public constant DENOMINATOR = 10000; // 1: 0.01%(0.0001), 100: 1%(0.01), 10000: 100%(1)

    uint256 public immutable START_TIME;
    uint256 public immutable EPOCH_LENGTH;
    uint256 public immutable WITHDRAW_TIME;

    address public bank;
    address public treasury;
    address public devWallet;

    IERC20 public stakedToken;

    uint256 public epochNumber; // increase one by one per epoch
    uint256 public totalAmount; // total staked amount

    mapping(uint256 => uint256) public apy; // epochNumber => apy, apyValue = (apy / DENOMINATOR * 100) %

    mapping(address => mapping(uint256 => uint256)) public amount; // staker => (epochNumber => stakedAmount)
    mapping(address => UserInfo) public userInfo; // staker => userInfo

    mapping(address => uint256) public referralRewards; // referral => referralReward
    mapping(address => uint256) public referralTotalRewards; // referral => referral => referralReward

    event LogSetDevWallet(address indexed devWallet);
    event LogSetTreasury(address indexed treasury);
    event LogSetBank(address indexed bank);
    event LogSetStakedToken(address indexed stakedToken);
    event LogSetAPY(uint256 indexed apy);
    event LogDeposit(
        address indexed staker,
        uint256 indexed epochNumber,
        uint256 indexed depositAmount
    );
    event LogSetReferral(address indexed user, address indexed referral);
    event LogWithdraw(
        address indexed staker,
        uint256 epochNumber,
        uint256 indexed withdrawAmount
    );
    event LogWithdrawReward(
        address indexed user,
        uint256 indexed epochNumber,
        uint256 indexed reward
    );
    event LogSetNewEpoch(uint256 indexed epochNumber);
    event LogWithdrawReferral(
        address indexed referral,
        uint256 indexed referralReward
    );
    event LogInjectFunds(
        uint256 indexed injectAmount,
        uint256 indexed rewardAmount
    );
    event LogEjectFunds(uint256 indexed ejectAmount);

    constructor(
        IERC20 _stakedToken,
        address _bank,
        uint256 _apy,
        address _treasury,
        address _devWallet,
        uint256 _startTime,
        uint256 _epochLength,
        uint256 _withdrawTime
    ) {
        setStakedToken(_stakedToken);
        setBank(_bank);
        _setAPY(_apy);
        setTreasury(_treasury);
        setDevWallet(_devWallet);
        START_TIME = _startTime;
        EPOCH_LENGTH = _epochLength;
        WITHDRAW_TIME = _withdrawTime;
    }

    function setDevWallet(address _devWallet) public onlyOwner {
        require(_devWallet != address(0), "setDevWallet: ZERO_ADDRESS");
        require(_devWallet != devWallet, "setDevWallet: SAME_ADDRESS");

        devWallet = _devWallet;

        emit LogSetDevWallet(devWallet);
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0), "setTreasury: ZERO_ADDRESS");
        require(_treasury != treasury, "setTreasury: ZERO_ADDRESS");

        treasury = _treasury;
        emit LogSetTreasury(treasury);
    }

    function setBank(address _bank) public onlyOwner {
        require(_bank != address(0), "setBank: ZERO_ADDRESS");
        require(_bank != bank, "setBank: SAME_ADDRESS");

        bank = _bank;

        emit LogSetBank(bank);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    function setStakedToken(IERC20 _stakedToken) public onlyOwner {
        stakedToken = _stakedToken;
        emit LogSetStakedToken(address(stakedToken));
    }

    function _setAPY(uint256 _apy) internal {
        apy[epochNumber] = _apy;
        emit LogSetAPY(_apy);
    }

    function setAPY(uint256 _apy) external onlyOwner {
        _setNewEpoch();
        _setAPY(_apy);
    }

    function deposit(uint256 _amount, address _referral)
        external
        whenNotPaused
        nonReentrant
    {
        _setNewEpoch();

        require(
            stakedToken.transferFrom(msg.sender, address(this), _amount),
            "deposit: TRANSFERFROM_FAIL"
        );

        totalAmount += _amount;

        if (epochNumber < 1) {
            amount[msg.sender][0] += _amount;
        } else {
            for (
                uint256 index = epochNumber - 1;
                index > userInfo[msg.sender].lastActionEpochNumber;
                index--
            ) {
                amount[msg.sender][index] = amount[msg.sender][
                    userInfo[msg.sender].lastActionEpochNumber
                ];
            }

            if (epochNumber == userInfo[msg.sender].lastActionEpochNumber) {
                amount[msg.sender][epochNumber] += _amount;
            } else {
                amount[msg.sender][epochNumber] =
                    amount[msg.sender][epochNumber - 1] +
                    _amount;
            }
        }

        if (
            userInfo[msg.sender].referrals == address(0) &&
            _referral != msg.sender &&
            _referral != address(0)
        ) {
            userInfo[msg.sender].referrals = _referral;
            emit LogSetReferral(msg.sender, _referral);
        }

        userInfo[msg.sender].lastActionEpochNumber = epochNumber;

        emit LogDeposit(msg.sender, epochNumber, _amount);
    }

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        bool hasReward = _withdrawReward();
        require(
            hasReward || _amount > 0,
            "withdraw: NO_REWARD_OR_ZERO_WITHDRAW"
        );

        userInfo[msg.sender].lastActionEpochNumber = epochNumber;

        if (_amount > 0) {
            uint256 withdrawStart = START_TIME +
                userInfo[msg.sender].requestEpochNumber *
                EPOCH_LENGTH;
            require(
                withdrawStart <= block.timestamp &&
                    block.timestamp < withdrawStart + WITHDRAW_TIME,
                "withdraw: TIME_OVER"
            );

            uint256 requestAmount = userInfo[msg.sender].requestAmount;
            uint256 enableAmount = amount[msg.sender][
                userInfo[msg.sender].requestEpochNumber - 1
            ];

            require(
                _amount <= enableAmount && _amount <= requestAmount,
                "withdraw: INSUFFICIENT_REQUEST_OR_ENABLE_AMOUNT"
            );

            userInfo[msg.sender].requestAmount -= _amount;

            uint256 withdrawFee = (_amount * WITHDRAW_FEE) / DENOMINATOR;

            require(
                stakedToken.transfer(msg.sender, _amount - withdrawFee),
                "withdraw: TRANSFER_FAIL"
            );

            require(
                stakedToken.transfer(
                    treasury,
                    (withdrawFee * (DENOMINATOR - DEV_FEE)) / DENOMINATOR
                ),
                "withdraw: TRANSFERFROM_TO_TREASURY_FAIL"
            );

            require(
                stakedToken.transfer(
                    devWallet,
                    (withdrawFee * DEV_FEE) / DENOMINATOR
                ),
                "withdraw: TRANSFERFROM_TO_DEV_FAIL"
            );

            totalAmount -= _amount;

            amount[msg.sender][epochNumber] -= _amount;

            emit LogWithdraw(msg.sender, epochNumber, _amount);
        }
    }

    function _withdrawReward() internal returns (bool hasReward) {
        _setNewEpoch();
        for (
            uint256 index = epochNumber;
            index > userInfo[msg.sender].lastActionEpochNumber;
            index--
        ) {
            amount[msg.sender][index] = amount[msg.sender][
                userInfo[msg.sender].lastActionEpochNumber
            ];
        }

        uint256 pendingReward;
        if (epochNumber > 1) {
            for (
                uint256 index = userInfo[msg.sender].pendingClaimEpochNumber;
                index < epochNumber - 1;
                index++
            ) {
                pendingReward +=
                    (amount[msg.sender][index] * apy[index]) /
                    DENOMINATOR;
            }
            userInfo[msg.sender].pendingClaimEpochNumber = epochNumber - 1;
        }

        if (pendingReward > 0) {
            hasReward = true;

            uint256 referralReward = (pendingReward * REFERRAL_PERCENT) /
                DENOMINATOR;

            pendingReward -= referralReward;
            uint256 withdrawFee = (pendingReward * WITHDRAW_FEE) / DENOMINATOR;

            require(
                stakedToken.transferFrom(
                    treasury,
                    msg.sender,
                    pendingReward - withdrawFee
                ),
                "_withdrawReward: TRANSFERFROM_FAIL"
            );

            require(
                stakedToken.transferFrom(
                    treasury,
                    devWallet,
                    (withdrawFee * DEV_FEE) / DENOMINATOR
                ),
                "_withdrawReward: TRANSFERFROM_TO_DEV_FAIL"
            );

            referralRewards[userInfo[msg.sender].referrals] += referralReward;

            userInfo[msg.sender].lastRewards = pendingReward;
            userInfo[msg.sender].totalRewards += pendingReward;

            emit LogWithdrawReward(msg.sender, epochNumber, pendingReward);
        } else {
            hasReward = false;
        }
    }

    function getPendingReward(address user)
        external
        view
        returns (uint256 pendingReward)
    {
        if (block.timestamp >= START_TIME + EPOCH_LENGTH) {
            uint256 newEpochNumber = (block.timestamp - START_TIME) /
                EPOCH_LENGTH;
            for (
                uint256 index = userInfo[user].pendingClaimEpochNumber;
                index < newEpochNumber;
                index++
            ) {
                uint256 amountValue = amount[user][index] > 0
                    ? amount[user][index]
                    : amount[user][userInfo[user].lastActionEpochNumber];
                uint256 apyValue = (
                    apy[index] > 0 ? apy[index] : apy[epochNumber]
                );
                pendingReward += (amountValue * apyValue) / DENOMINATOR;
            }

            pendingReward -= (pendingReward * REFERRAL_PERCENT) / DENOMINATOR;
        }
    }

    function _setNewEpoch() internal {
        if (block.timestamp < START_TIME) return;
        uint256 newEpochNumber = (block.timestamp - START_TIME) /
            EPOCH_LENGTH +
            1;
        if (newEpochNumber > epochNumber) {
            uint256 apyValue = apy[epochNumber];

            for (
                uint256 index = epochNumber + 1;
                index <= newEpochNumber;
                index++
            ) {
                apy[index] = apyValue;
            }

            epochNumber = newEpochNumber;

            emit LogSetNewEpoch(epochNumber);
        }
    }

    function withdrawReferral() external whenNotPaused nonReentrant {
        require(
            referralRewards[msg.sender] > 0,
            "withdrawReferral: ZERO_AMOUNT"
        );
        require(
            stakedToken.transferFrom(
                treasury,
                msg.sender,
                referralRewards[msg.sender]
            ),
            "withdrawReferral: TRANSFER_FAIL"
        );
        referralTotalRewards[msg.sender] += referralRewards[msg.sender];

        emit LogWithdrawReferral(msg.sender, referralRewards[msg.sender]);

        referralRewards[msg.sender] = 0;
    }

    function withdrawRequest(uint256 _amount)
        external
        whenNotPaused
        nonReentrant
    {
        _setNewEpoch();
        userInfo[msg.sender].requestEpochNumber = epochNumber > 0
            ? epochNumber
            : 1;
        userInfo[msg.sender].requestAmount = _amount;
    }

    /**
     * @notice Inject funds and rewards to distribute to stakers.
     */
    function injectFunds(uint256 _injectAmount, uint256 _rewardAmount)
        external
        onlyOwner
    {
        require(
            stakedToken.transferFrom(bank, address(this), _injectAmount),
            "injectFunds: TRANSFERFROM_INJECT_FAIL"
        );
        require(
            stakedToken.transferFrom(bank, treasury, _rewardAmount),
            "injectFunds: TRANSFERFROM_REWARD_FAIL"
        );

        emit LogInjectFunds(_injectAmount, _rewardAmount);
    }

    /**
     * @notice Eject funds to make profit for stakers.
     */
    function ejectFunds(uint256 _amount) external onlyOwner {
        uint256 ejectEnabledAmount = stakedToken.balanceOf(address(this));

        require(
            _amount <= ejectEnabledAmount,
            "ejectFunds: OVERFLOW_EJECT_ENABLED_AMOUNT"
        );

        require(
            stakedToken.transfer(bank, _amount),
            "ejectFunds: TRANSFER_FAIL"
        );

        emit LogEjectFunds(_amount);
    }
}
