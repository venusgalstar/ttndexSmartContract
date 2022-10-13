// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./utils/SafeERC20.sol";
import "./utils/Ownable.sol";

contract TTNDEXReferral is Ownable {
    using SafeERC20 for IERC20;

    //Max min withdraw amount : 100 TTNPs
    uint256 public constant MAX_MIN_AMOUNT = 100 * 10**18;

    IERC20 public immutable ttnp;

    //Minimum commision withdraw amount
    uint256 public minWithdraw = 0.3 * 10**18;

    mapping(address => bool) public operators;
    mapping(address => address) public referrers; // user address => referrer address
    mapping(address => uint256) public referralsCount; // referrer address => referrals count
    mapping(address => uint256) public totalReferralCommissions; // referrer address => total referral commissions
    mapping(address => uint256) public pendingReferralCommissions; // referrer address => pending referral commissions

    event ReferralRecorded(address indexed user, address indexed referrer);
    event ReferralCommissionRecorded(
        address indexed referrer,
        uint256 commission
    );
    event OperatorUpdated(address indexed operator, bool indexed status);
    event ReferralRewardWithdraw(address indexed user, uint256 rewardAmount);

    constructor(address _ttnp) {
        ttnp = IERC20(_ttnp);
    }

    modifier onlyOperator() {
        require(operators[msg.sender], "Operator: caller is not the operator");
        _;
    }

    function recordReferral(address _user, address _referrer)
        public
        onlyOperator
    {
        if (
            _user != address(0) &&
            _referrer != address(0) &&
            _user != _referrer &&
            referrers[_user] == address(0)
        ) {
            referrers[_user] = _referrer;
            referralsCount[_referrer] += 1;
            emit ReferralRecorded(_user, _referrer);
        }
    }

    function recordReferralCommission(address _referrer, uint256 _commission)
        public
        onlyOperator
    {
        if (_referrer != address(0) && _commission > 0) {
            totalReferralCommissions[_referrer] += _commission;
            pendingReferralCommissions[_referrer] += _commission;

            emit ReferralCommissionRecorded(_referrer, _commission);
        }
    }

    // Get the referrer address that referred the user
    function getReferrer(address _user) public view returns (address) {
        return referrers[_user];
    }

    // Update the status of the operator
    function updateOperator(address _operator, bool _status)
        external
        onlyOwner
    {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    function setMinCommisionWithdraw(uint256 _amount) external onlyOwner {
        require(_amount <= MAX_MIN_AMOUNT, "Invalid amount");
        minWithdraw = _amount;
    }

    // Owner can drain tokens that are sent here by mistake
    function drainERC20Token(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        _token.safeTransfer(_to, _amount);
    }

    function withdrawReferralReward() external {
        if (pendingReferralCommissions[msg.sender] >= minWithdraw) {
            ttnp.safeTransfer(
                msg.sender,
                pendingReferralCommissions[msg.sender]
            );

            emit ReferralRewardWithdraw(
                msg.sender,
                pendingReferralCommissions[msg.sender]
            );

            pendingReferralCommissions[msg.sender] = 0;
        }
    }
}
