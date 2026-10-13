// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MihenkPay
/// @notice Performance-based KOL payments. A sponsor (project or agency) locks a
///         stablecoin fee for one KOL. Mihenk measures the post off-chain (delivery,
///         time live, real reach) and settles on-chain. Part of the fee is released
///         on delivery, the rest when the reach target is met; anything not earned
///         goes back to the sponsor. Payouts are never tied to a token's price.
/// @dev    Privacy: no social handles are stored. Only hashes of the off-chain terms
///         and of the measured result are written on-chain.
contract MihenkPay is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum Status {
        None,
        Funded, // sponsor locked the fee, waiting for the KOL to accept
        Accepted, // KOL accepted with the payout wallet (proves wallet control)
        Settled, // Mihenk posted the result, dispute window running
        Disputed, // sponsor or KOL disputed the result
        Closed, // funds distributed
        Refunded // cancelled or expired, sponsor refunded in full
    }

    struct Campaign {
        address sponsor;
        address kol;
        IERC20 token;
        uint128 amount; // total locked
        uint128 kolPayout; // gross amount earned by the KOL, set at settlement
        uint16 deliveryBps; // share earned on delivery; the rest is earned on reach
        uint16 feeBps; // Mihenk fee on the KOL payout, snapshotted at creation
        uint40 postDeadline; // KOL must accept (and post) before this
        uint40 settleDeadline; // Mihenk must settle before this, else sponsor refund
        uint40 disputeEnds; // end of the dispute window after settlement
        Status status;
        bytes32 termsHash; // hash of the off-chain campaign terms
        bytes32 resultHash; // hash of the off-chain measurement report
    }

    // ------------------------------------------------------------- constants

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10% hard cap
    uint40 public constant MIN_DISPUTE_WINDOW = 1 hours;
    uint40 public constant MAX_DISPUTE_WINDOW = 14 days;
    uint40 public constant RESOLVE_TIMEOUT = 30 days;

    // --------------------------------------------------------------- storage

    uint256 public nextId = 1;
    mapping(uint256 => Campaign) public campaigns;
    mapping(address => bool) public allowedToken;

    address public verifier; // Mihenk measurement oracle
    address public feeRecipient;
    uint16 public feeBps;
    uint40 public disputeWindow = 3 days;

    // ---------------------------------------------------------------- events

    event CampaignCreated(
        uint256 indexed id,
        address indexed sponsor,
        address indexed kol,
        address token,
        uint256 amount,
        uint16 deliveryBps,
        uint16 feeBps,
        uint40 postDeadline,
        uint40 settleDeadline,
        bytes32 termsHash
    );
    event CampaignAccepted(uint256 indexed id);
    event CampaignCancelled(uint256 indexed id);
    event CampaignSettled(
        uint256 indexed id, bool delivered, bool reachHit, uint256 kolPayout, bytes32 resultHash, uint40 disputeEnds
    );
    event CampaignDisputed(uint256 indexed id, address indexed by);
    event DisputeResolved(uint256 indexed id, uint256 kolPayout, bytes32 resultHash);
    event CampaignClosed(uint256 indexed id, uint256 kolNet, uint256 fee, uint256 sponsorRefund);
    event CampaignRefunded(uint256 indexed id, uint256 amount);

    event VerifierSet(address verifier);
    event FeeSet(uint16 feeBps, address feeRecipient);
    event TokenAllowed(address token, bool allowed);
    event DisputeWindowSet(uint40 window);

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error TokenNotAllowed();
    error InvalidAmount();
    error InvalidBps();
    error InvalidDeadlines();
    error InvalidWindow();
    error NotVerifier();
    error NotSponsor();
    error NotKol();
    error NotParty();
    error WrongStatus(Status current);
    error TooLate();
    error TooEarly();
    error FeeOnTransferToken();
    error PayoutTooHigh();

    // ----------------------------------------------------------- constructor

    constructor(address owner_, address verifier_, address feeRecipient_, uint16 feeBps_) Ownable(owner_) {
        _setVerifier(verifier_);
        _setFee(feeBps_, feeRecipient_);
    }

    // --------------------------------------------------------------- admin

    function setVerifier(address verifier_) external onlyOwner {
        _setVerifier(verifier_);
    }

    function setFee(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        _setFee(feeBps_, feeRecipient_);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setDisputeWindow(uint40 window) external onlyOwner {
        if (window < MIN_DISPUTE_WINDOW || window > MAX_DISPUTE_WINDOW) revert InvalidWindow();
        disputeWindow = window;
        emit DisputeWindowSet(window);
    }

    // ------------------------------------------------------------ sponsor

    /// @notice Lock a KOL fee. The sponsor must have approved `amount` first.
    function createCampaign(
        address kol,
        address token,
        uint128 amount,
        uint16 deliveryBps,
        uint40 postDeadline,
        uint40 settleDeadline,
        bytes32 termsHash
    ) external nonReentrant returns (uint256 id) {
        if (kol == address(0)) revert ZeroAddress();
        if (!allowedToken[token]) revert TokenNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (deliveryBps > BPS) revert InvalidBps();
        if (postDeadline <= block.timestamp || settleDeadline <= postDeadline) revert InvalidDeadlines();

        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();

        id = nextId++;
        Campaign storage c = campaigns[id];
        c.sponsor = msg.sender;
        c.kol = kol;
        c.token = t;
        c.amount = amount;
        c.deliveryBps = deliveryBps;
        c.feeBps = feeBps;
        c.postDeadline = postDeadline;
        c.settleDeadline = settleDeadline;
        c.status = Status.Funded;
        c.termsHash = termsHash;

        emit CampaignCreated(
            id, msg.sender, kol, token, amount, deliveryBps, feeBps, postDeadline, settleDeadline, termsHash
        );
    }

    /// @notice Sponsor can take the money back while the KOL has not accepted yet.
    function cancelBeforeAccept(uint256 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (c.status != Status.Funded) revert WrongStatus(c.status);
        c.status = Status.Refunded;
        emit CampaignCancelled(id);
        emit CampaignRefunded(id, c.amount);
        c.token.safeTransfer(c.sponsor, c.amount);
    }

    // ---------------------------------------------------------------- KOL

    /// @notice The KOL accepts from the payout wallet, which proves control of it.
    function acceptCampaign(uint256 id) external {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.kol) revert NotKol();
        if (c.status != Status.Funded) revert WrongStatus(c.status);
        if (block.timestamp > c.postDeadline) revert TooLate();
        c.status = Status.Accepted;
        emit CampaignAccepted(id);
    }

    // ----------------------------------------------------------- verifier

    /// @notice Mihenk posts the measured outcome. Reach can only count if delivered.
    function settle(uint256 id, bool delivered, bool reachHit, bytes32 resultHash) external {
        if (msg.sender != verifier) revert NotVerifier();
        Campaign storage c = campaigns[id];
        if (c.status != Status.Accepted) revert WrongStatus(c.status);
        if (block.timestamp > c.settleDeadline) revert TooLate();

        uint256 payout;
        if (delivered) {
            payout = (uint256(c.amount) * c.deliveryBps) / BPS;
            if (reachHit) payout = c.amount;
        }

        c.kolPayout = uint128(payout);
        c.resultHash = resultHash;
        c.status = Status.Settled;
        c.disputeEnds = uint40(block.timestamp) + disputeWindow;

        emit CampaignSettled(id, delivered, delivered && reachHit, payout, resultHash, c.disputeEnds);
    }

    // ------------------------------------------------------------ disputes

    function dispute(uint256 id) external {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.sponsor && msg.sender != c.kol) revert NotParty();
        if (c.status != Status.Settled) revert WrongStatus(c.status);
        if (block.timestamp >= c.disputeEnds) revert TooLate();
        c.status = Status.Disputed;
        emit CampaignDisputed(id, msg.sender);
    }

    /// @notice Owner resolves a dispute with a corrected payout; funds move at once.
    function resolveDispute(uint256 id, uint128 kolPayout, bytes32 resultHash) external onlyOwner nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Disputed) revert WrongStatus(c.status);
        if (kolPayout > c.amount) revert PayoutTooHigh();
        c.kolPayout = kolPayout;
        c.resultHash = resultHash;
        emit DisputeResolved(id, kolPayout, resultHash);
        _distribute(id, c);
    }

    // -------------------------------------------------------------- payout

    /// @notice Anyone can close a settled campaign once the dispute window ends.
    ///         An unresolved dispute falls back to the verifier's result after
    ///         RESOLVE_TIMEOUT so funds can never be stuck.
    function finalize(uint256 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status == Status.Settled) {
            if (block.timestamp < c.disputeEnds) revert TooEarly();
        } else if (c.status == Status.Disputed) {
            if (block.timestamp < uint256(c.disputeEnds) + RESOLVE_TIMEOUT) revert TooEarly();
        } else {
            revert WrongStatus(c.status);
        }
        _distribute(id, c);
    }

    /// @notice If Mihenk never settles in time, the sponsor gets everything back.
    function refundExpired(uint256 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != Status.Funded && c.status != Status.Accepted) revert WrongStatus(c.status);
        if (block.timestamp <= c.settleDeadline) revert TooEarly();
        c.status = Status.Refunded;
        emit CampaignRefunded(id, c.amount);
        c.token.safeTransfer(c.sponsor, c.amount);
    }

    // ------------------------------------------------------------- views

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return campaigns[id];
    }

    // ----------------------------------------------------------- internal

    function _distribute(uint256 id, Campaign storage c) internal {
        c.status = Status.Closed;
        uint256 gross = c.kolPayout;
        uint256 fee = (gross * c.feeBps) / BPS;
        uint256 kolNet = gross - fee;
        uint256 refund = uint256(c.amount) - gross;

        emit CampaignClosed(id, kolNet, fee, refund);

        if (kolNet > 0) c.token.safeTransfer(c.kol, kolNet);
        if (fee > 0) c.token.safeTransfer(feeRecipient, fee);
        if (refund > 0) c.token.safeTransfer(c.sponsor, refund);
    }

    function _setVerifier(address verifier_) internal {
        if (verifier_ == address(0)) revert ZeroAddress();
        verifier = verifier_;
        emit VerifierSet(verifier_);
    }

    function _setFee(uint16 feeBps_, address feeRecipient_) internal {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidBps();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        emit FeeSet(feeBps_, feeRecipient_);
    }
}
