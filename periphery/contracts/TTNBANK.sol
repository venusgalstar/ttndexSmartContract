// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./interfaces/IERC20.sol";
import "./utils/Ownable.sol";
import "./utils/Pausable.sol";
import "./utils/ReentrancyGuard.sol";

contract TTNBANK is Ownable, Pausable, ReentrancyGuard {
    uint256 public constant MIN_APY = 1; // for only test
    uint256 public constant MAX_APY = 10**6; // for only test

    uint256 public constant REFERRAL_PERCENT = 1000; // 10%
    uint256 public constant WITHDRAW_FEE = 100; // 1%
    uint256 public constant DEV_FEE = 1000; // 10%

    uint256 public constant DENOMINATOR = 10000; // 1: 0.01%(0.0001), 100: 1%(0.01), 10000: 100%(1)

    uint256 public immutable startTime;
    uint256 public immutable epochLength;

    address public bank;
    address public treasury;
    address public devWallet;

    IERC20 public stakedToken;

    uint256 public epochNumber; // increase one by one per epoch
    uint256 public totalAmount; // total staked amount

    mapping(uint256 => uint256) public apy; // epochNumber => apy, apyValue = (apy / DENOMINATOR * 100) %

    mapping(address => mapping(uint256 => uint256)) public amount; // staker => (epochNumber => stakedAmount)
    mapping(address => uint256) public lastClaimEpochNumber; // staker => lastClaimEpochNumber
    mapping(address => uint256) public lastActionEpochNumber; // staker => lastActionEpochNumber
    mapping(address => uint256) public lastRewards; // staker => lastReward
    mapping(address => uint256) public totalRewards; // staker => totalReward
    mapping(address => address) public referrals; // staker => referral

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
        uint256 _epochLength,
        uint256 _apy,
        address _treasury,
        address _devWallet
    ) {
        setStakedToken(_stakedToken);
        setBank(_bank);
        epochLength = _epochLength;
        apy[0] = _apy;
        _setAPY(_apy);
        setTreasury(_treasury);
        setDevWallet(_devWallet);
        startTime = block.timestamp;
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
        apy[epochNumber + 1] = _apy;
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

        for (
            uint256 index = epochNumber;
            index > lastActionEpochNumber[msg.sender] + 1;
            index--
        ) {
            amount[msg.sender][index] = amount[msg.sender][
                lastActionEpochNumber[msg.sender] + 1
            ];
        }

        if (epochNumber == lastActionEpochNumber[msg.sender]) {
            amount[msg.sender][epochNumber + 1] += _amount;
        } else {
            amount[msg.sender][epochNumber + 1] =
                amount[msg.sender][epochNumber] +
                _amount;
        }

        if (
            referrals[msg.sender] == address(0) &&
            _referral != msg.sender &&
            _referral != address(0)
        ) {
            referrals[msg.sender] = _referral;
            emit LogSetReferral(msg.sender, _referral);
        }

        lastActionEpochNumber[msg.sender] = epochNumber;

        emit LogDeposit(msg.sender, epochNumber + 1, _amount);
    }

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "withdraw: ZERO_WITHDRAW_AMOUNT");

        _withdrawReward();

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

        if (epochNumber == lastActionEpochNumber[msg.sender]) {
            require(
                amount[msg.sender][epochNumber + 1] >= _amount,
                "withdraw: INSUFFICIENT_STAKED_NEXT_BALANCE"
            );

            amount[msg.sender][epochNumber + 1] -= _amount;
        } else {
            require(
                amount[msg.sender][epochNumber] >= _amount,
                "withdraw: INSUFFICIENT_STAKED_BALANCE"
            );

            amount[msg.sender][epochNumber + 1] =
                amount[msg.sender][epochNumber] -
                _amount;
        }

        lastActionEpochNumber[msg.sender] = epochNumber;

        emit LogWithdraw(msg.sender, epochNumber + 1, _amount);
    }

    function _withdrawReward() internal returns (bool hasReward) {
        _setNewEpoch();
        for (
            uint256 index = epochNumber + 1;
            index > lastActionEpochNumber[msg.sender] + 1;
            index--
        ) {
            amount[msg.sender][index] = amount[msg.sender][
                lastActionEpochNumber[msg.sender] + 1
            ];
        }

        uint256 pendingReward;
        for (
            uint256 index = lastClaimEpochNumber[msg.sender];
            index < epochNumber;
            index++
        ) {
            pendingReward +=
                (amount[msg.sender][index] * apy[index]) /
                DENOMINATOR;
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

            referralRewards[referrals[msg.sender]] += referralReward;

            lastClaimEpochNumber[msg.sender] = epochNumber;
            lastRewards[msg.sender] = pendingReward;
            totalRewards[msg.sender] += pendingReward;

            emit LogWithdrawReward(msg.sender, epochNumber, pendingReward);
        } else {
            hasReward = false;
        }
    }

    function withdrawReward() external whenNotPaused nonReentrant {
        require(_withdrawReward(), "withdrawReward: NO_REWARD");
        lastActionEpochNumber[msg.sender] = epochNumber;
    }

    function getPendingReward(address user)
        external
        view
        returns (uint256 pendingReward)
    {
        for (
            uint256 index = lastClaimEpochNumber[user];
            index < lastActionEpochNumber[user];
            index++
        ) {
            pendingReward += (amount[user][index] * apy[index]) / DENOMINATOR;
        }

        uint256 newEpochNumber = (block.timestamp - startTime) / epochLength;
        for (
            uint256 index = lastActionEpochNumber[user];
            index < newEpochNumber;
            index++
        ) {
            uint256 amountValue = (index == lastActionEpochNumber[user])
                ? amount[user][index]
                : amount[user][lastActionEpochNumber[user] + 1];
            uint256 apyValue = (
                apy[index] > 0 ? apy[index] : (apy[epochNumber + 1] > 0)
                    ? apy[epochNumber + 1]
                    : apy[epochNumber]
            );
            pendingReward += (amountValue * apyValue) / DENOMINATOR;
        }

        pendingReward -= (pendingReward * REFERRAL_PERCENT) / DENOMINATOR;
    }

    function _setNewEpoch() internal {
        uint256 newEpochNumber = (block.timestamp - startTime) / epochLength;
        if (newEpochNumber > epochNumber) {
            uint256 apyValue = apy[epochNumber];

            for (
                uint256 index = epochNumber + 1;
                index <= newEpochNumber + 1;
                index++
            ) {
                apy[index] = apy[index] > 0 ? apy[index] : apyValue;
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
