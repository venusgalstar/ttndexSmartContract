// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./utils/ConfirmedOwner.sol";
import "./utils/VRFV2WrapperConsumerBase.sol";
import "./interfaces/IRandomNumberGenerator.sol";
import "./interfaces/ITTNDEXLottery.sol";

contract RandomNumberGenerator is
    IRandomNumberGenerator,
    VRFV2WrapperConsumerBase,
    ConfirmedOwner
{
    address public immutable linkAddress;
    address public immutable wrapperAddress;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 public callbackGasLimit = 100000;

    // Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
    // VRFV2Wrapper.getConfig().maxNumWords = 10 when network is bsc mainnet
    uint32 public numWords = 1;

    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 50;
    uint256 public maxFee = 2 * 10 ** 17; // 0.2 LINK
    address public ttnDexLottery;

    bool public latestRequestStatus;
    uint256 public latestRequestPaidAmount;
    uint256 public latestRequestId;
    uint32 public randomResult;
    uint256 public latestLotteryId;

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    constructor(address _linkAddress, address _wrapperAddress)
        ConfirmedOwner(msg.sender)
        VRFV2WrapperConsumerBase(_linkAddress, _wrapperAddress)
    {
        linkAddress = _linkAddress;
        wrapperAddress = _wrapperAddress;
    }

    function requestRandomWords() internal returns (uint256 requestId) {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );

        latestRequestStatus = false;
        latestRequestPaidAmount = VRF_V2_WRAPPER.calculateRequestPrice(
            callbackGasLimit
        );

        require(latestRequestPaidAmount <= maxFee, "Must less than maxFee");

        emit RequestSent(requestId, numWords);
        return requestId;
    }

    /**
     * @notice Request randomness from a user-provided seed
     */
    function getRandomNumber() external override {
        require(msg.sender == ttnDexLottery, "Only TTNDEXLottery");
        require(
            LinkTokenInterface(linkAddress).balanceOf(address(this)) >= maxFee,
            "Not enough LINK tokens"
        );

        latestRequestId = requestRandomWords();
    }

    /**
     * @notice Callback function used by ChainLink's VRF Coordinator
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(latestRequestId == _requestId, "Wrong requestId");
        require(latestRequestPaidAmount > 0, "request not found");

        emit RequestFulfilled(
            _requestId,
            _randomWords,
            latestRequestPaidAmount
        );

        latestRequestStatus = true;
        latestRequestPaidAmount = 0;

        randomResult = uint32(1000000 + (_randomWords[0] % 1000000));
        latestLotteryId = ITTNDEXLottery(ttnDexLottery).viewCurrentLotteryId();
    }

    /**
     * @notice View latestLotteryId
     */
    function viewLatestLotteryId() external view override returns (uint256) {
        return latestLotteryId;
    }

    /**
     * @notice View random result
     */
    function viewRandomResult() external view override returns (uint32) {
        return randomResult;
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() external onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    function setNumWords(uint32 _numWords) external onlyOwner {
        numWords = _numWords;
    }

    function setRequestConfirmations(uint16 _requestConfirmations)
        external
        onlyOwner
    {
        requestConfirmations = _requestConfirmations;
    }

    function setCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
        callbackGasLimit = _callbackGasLimit;
    }

    /**
     * @notice Change the maxFee
     * @param _maxFee: new maxFee (in LINK)
     */
    function setMaxFee(uint256 _maxFee) external onlyOwner {
        maxFee = _maxFee;
    }

    /**
     * @notice Set the address for the TTNDEXLottery
     * @param _ttnDexLottery: address of the TTNDEX lottery
     */
    function setLotteryAddress(address _ttnDexLottery) external onlyOwner {
        ttnDexLottery = _ttnDexLottery;
    }
}
