// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./IERC20.sol";
import "./Ownable.sol";
import "./Pausable.sol";
import "./ReentrancyGuard.sol";

contract TTNBANK is Ownable, Pausable, ReentrancyGuard {
    uint256 public constant MIN_DEPOSIT_AMOUNT = 20; // Note: 20 * 10**decimals
    uint256 public constant MAX_DEPOSIT_AMOUNT = 25000; // Note: 25000 * 10**decimals

    uint256 public constant MIN_APY = 1; // for only test
    uint256 public constant MAX_APY = 1000000; // for only test

    uint256 public constant REFERRAL_PERCENT = 1000;
    uint256 public constant DEPOSIT_FEE = 100;
    uint256 public constant WITHDRAW_FEE = 50;
    uint256 public constant DEV_FEE = 1000;

    uint256 public constant DENOMINATOR = 10000; // 1: 0.01%(0.0001), 100: 1%(0.01), 10000: 100%(1)

    address public treasury;
    address public devWallet;

    uint256 public immutable startTime;
    uint256 public immutable epochLength;

    IERC20 public token;

    uint256 public epochNumber; // increase one by one per epoch

    mapping(uint256 => uint256) public apy; // epochNumber => apy, apyValue = (apy / DENOMINATOR * 100) %
    mapping(uint256 => uint256) public totalAmount; // epochNumber => totalStakedAmount

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
    event LogSetToken(address indexed token);
    event LogSetAPY(uint256 indexed apy);
    event LogDeposit(
        address indexed staker,
        uint256 indexed epochNumber,
        uint256 indexed stakedAmount
    );
    event LogSetReferal(address indexed user, address indexed referral);
    event LogWithdraw(
        address indexed staker,
        uint256 epochNumber,
        uint256 indexed stakedAmount
    );
    event LogWithdrawReward(
        address indexed user,
        uint256 indexed epochNumber,
        uint256 indexed reward
    );
    event LogSetNewEpoch(uint256 indexed epochNumber);
    event LogWithdrawReferal(
        address indexed referral,
        uint256 indexed referralReward
    );

    constructor(
        IERC20 _token,
        uint256 _epochLength,
        uint256 _apy,
        address _treasury,
        address _devWallet
    ) {
        setToken(_token);
        epochLength = _epochLength;
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

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    function setToken(IERC20 _token) public onlyOwner {
        require(address(_token) != address(0), "setToken: ZERO_ADDRESS");
        require(address(_token) != address(token), "setToken: SAME_ADDRESS");

        token = _token;
        emit LogSetToken(address(token));
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
        require(
            MIN_DEPOSIT_AMOUNT * 10**token.decimals() <= _amount &&
                _amount <= MAX_DEPOSIT_AMOUNT * 10**token.decimals(),
            "deposit: OUT_BOUNDARY"
        );

        _setNewEpoch();

        uint256 depositFee = (_amount * DEPOSIT_FEE) / DENOMINATOR;

        require(
            token.transferFrom(msg.sender, address(this), _amount - depositFee),
            "deposit: TRANSFERFROM_FAIL"
        );

        require(
            token.transferFrom(
                msg.sender,
                treasury,
                (depositFee * (DENOMINATOR - DEV_FEE)) / DENOMINATOR
            ),
            "deposit: TRANSFERFROM_TO_TREASURY_FAIL"
        );

        require(
            token.transferFrom(
                msg.sender,
                devWallet,
                (depositFee * DEV_FEE) / DENOMINATOR
            ),
            "deposit: TRANSFERFROM_TO_DEV_FAIL"
        );

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

        if (totalAmount[epochNumber + 1] > 0) {
            totalAmount[epochNumber + 1] += _amount;
        } else {
            totalAmount[epochNumber + 1] = totalAmount[epochNumber] + _amount;
        }

        if (
            referrals[msg.sender] == address(0) &&
            _referral != msg.sender &&
            _referral != address(0)
        ) {
            referrals[msg.sender] = _referral;
            emit LogSetReferal(msg.sender, _referral);
        }

        lastActionEpochNumber[msg.sender] = epochNumber;

        emit LogDeposit(
            msg.sender,
            epochNumber + 1,
            amount[msg.sender][epochNumber + 1]
        );
    }

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "withdraw: ZERO_WITHDRAW_AMOUNT");

        _withdrawReward();

        uint256 withdrawFee = (_amount * WITHDRAW_FEE) / DENOMINATOR;

        require(
            token.transfer(msg.sender, _amount - withdrawFee),
            "withdraw: TRANSFER_FAIL"
        );

        require(
            token.transfer(
                treasury,
                (withdrawFee * (DENOMINATOR - DEV_FEE)) / DENOMINATOR
            ),
            "withdraw: TRANSFER_TO_TREASURY_FAIL"
        );

        require(
            token.transfer(devWallet, (withdrawFee * DEV_FEE) / DENOMINATOR),
            "withdraw: TRANSFER_TO_DEV_FAIL"
        );

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

        if (totalAmount[epochNumber + 1] > 0) {
            require(
                totalAmount[epochNumber + 1] >= _amount,
                "withdraw: INSUFFICIENT_TOTAL_STAKED_NEXT_BALANCE"
            );

            totalAmount[epochNumber + 1] -= _amount;
        } else {
            require(
                totalAmount[epochNumber] >= _amount,
                "withdraw: INSUFFICIENT_TOTAL_STAKED_NEXT_BALANCE"
            );

            totalAmount[epochNumber + 1] = totalAmount[epochNumber] - _amount;
        }

        emit LogWithdraw(
            msg.sender,
            epochNumber + 1,
            amount[msg.sender][epochNumber + 1]
        );
    }

    function _withdrawReward() internal returns (bool hasReward) {
        _setNewEpoch();
        for (
            uint256 index = epochNumber;
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
                totalAmount[index];
        }

        if (pendingReward > 0) {
            hasReward = true;
            uint256 withdrawRewardFee = (pendingReward * WITHDRAW_FEE) /
                DENOMINATOR;

            uint256 userReward = pendingReward - withdrawRewardFee;
            uint256 referralReward = (userReward * REFERRAL_PERCENT) /
                DENOMINATOR;

            require(
                token.transfer(msg.sender, userReward - referralReward),
                "_withdrawReward: TRANSFER_FAIL"
            );

            referralRewards[referrals[msg.sender]] += referralReward;

            require(
                token.transfer(
                    treasury,
                    (withdrawRewardFee * (DENOMINATOR - DEV_FEE)) / DENOMINATOR
                ),
                "_withdrawReward: TRANSFER_TO_TREASURY_FAIL"
            );

            require(
                token.transfer(
                    devWallet,
                    (withdrawRewardFee * DEV_FEE) / DENOMINATOR
                ),
                "_withdrawReward: TRANSFER_TO_DEV_FAIL"
            );

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
            pendingReward +=
                (amount[user][index] * apy[index]) /
                totalAmount[index];
        }

        uint256 newEpochNumber = epochLength +
            (block.timestamp - startTime - epochLength * epochNumber) /
            epochLength;
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
            uint256 totalAmountValue = (totalAmount[index] > 0)
                ? totalAmount[index]
                : totalAmount[epochNumber];
            pendingReward += (amountValue * apyValue) / totalAmountValue;
        }
    }

    function _setNewEpoch() internal {
        uint256 delta = block.timestamp - startTime;
        if (delta >= epochLength * (epochNumber + 1)) {
            uint256 increaseValue = (delta - epochLength * epochNumber) /
                epochLength;

            uint256 apyValue = apy[epochNumber];
            uint256 totalAmountValue = totalAmount[epochNumber];

            for (
                uint256 index = epochNumber + 1;
                index <= epochNumber + increaseValue + 1;
                index++
            ) {
                apy[index] = apy[index] > 0 ? apy[index] : apyValue;
                totalAmount[index] = totalAmount[index] > 0
                    ? totalAmount[index]
                    : totalAmountValue;
            }

            epochNumber += increaseValue;

            emit LogSetNewEpoch(epochNumber);
        }
    }

    function withdrawReferal() external whenNotPaused nonReentrant {
        require(
            referralRewards[msg.sender] > 0,
            "withdrawReferal: ZERO_AMOUNT"
        );
        require(
            token.transfer(msg.sender, referralRewards[msg.sender]),
            "withdrawReferal: TRANSFER_FAIL"
        );
        referralTotalRewards[msg.sender] += referralRewards[msg.sender];
        referralRewards[msg.sender] = 0;

        emit LogWithdrawReferal(msg.sender, referralRewards[msg.sender]);
    }
}
