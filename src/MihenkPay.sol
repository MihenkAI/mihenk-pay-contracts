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
///
///         v2:
///         - A payout the token refuses (for example to a USDC-blacklisted address) no
///           longer blocks the other payouts: it is credited to that address and can be
///           claimed later by that address only, so funds cannot get stuck.
///         - The fee recipient is fixed per campaign at creation, like the fee rate.
///         - The sponsor sets a minimum time after acceptance before Mihenk can settle.
///         - The dispute window is at least 24 hours.
contract MihenkPay is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum Status {
        None,
        Funded, // sponsor locked the fee, waiting for the KOL to accept
        Accepted, // KOL accepted with the payout wallet (proves wallet control)
        Settled, // Mihenk posted the result, dispute window running
        Disputed, // sponsor or KOL disputed the result
        Closed, // funds distributed (or credited for claim)
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
        address feeRecipient; // Mihenk fee recipient, snapshotted at creation
        uint40 minLive; // seconds after acceptance before Mihenk may settle
        uint40 acceptedAt; // when the KOL accepted
        bytes32 termsHash; // hash of the off-chain campaign terms
        bytes32 resultHash; // hash of the off-chain measurement report
    }

    // ------------------------------------------------------------- constants

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10% hard cap
    uint40 public constant MIN_DISPUTE_WINDOW = 24 hours;
    uint40 public constant MAX_DISPUTE_WINDOW = 14 days;
    uint40 public constant RESOLVE_TIMEOUT = 30 days;

    // --------------------------------------------------------------- storage

    uint256 public nextId = 1;
    mapping(uint256 => Campaign) internal campaigns; // read with getCampaign()
    mapping(address => bool) public allowedToken;

    /// @notice Payouts the token refused to transfer; only the account itself can claim them.
    mapping(address token => mapping(address account => uint256)) public owed;

    address public verifier; // Mihenk measurement oracle
    address public feeRecipient; // for campaigns created from now on
    uint16 public feeBps; // for campaigns created from now on
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
    event CampaignTerms(uint256 indexed id, address feeRecipient, uint40 minLive);
    event CampaignAccepted(uint256 indexed id);
    event CampaignCancelled(uint256 indexed id);
    event CampaignSettled(
        uint256 indexed id, bool delivered, bool reachHit, uint256 kolPayout, bytes32 resultHash, uint40 disputeEnds
    );
    event CampaignDisputed(uint256 indexed id, address indexed by);
    event DisputeResolved(uint256 indexed id, uint256 kolPayout, bytes32 resultHash);
    event CampaignClosed(uint256 indexed id, uint256 kolNet, uint256 fee, uint256 sponsorRefund);
    event CampaignRefunded(uint256 indexed id, uint256 amount);
    event PayoutDeferred(address indexed token, address indexed account, uint256 amount);
    event Claimed(address indexed token, address indexed account, uint256 amount);

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
    error NothingToClaim();

    // ----------------------------------------------------------- constructor

    constructor(address owner_, address verifier_, address feeRecipient_, uint16 feeBps_) Ownable(owner_) {
        _setVerifier(verifier_);
        _setFee(feeBps_, feeRecipient_);
    }

    // --------------------------------------------------------------- admin

    function setVerifier(address verifier_) external onlyOwner {
        _setVerifier(verifier_);
    }

    /// @notice Applies only to campaigns created afterwards.
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
    /// @param minLive Seconds that must pass after the KOL accepts before Mihenk can settle
    ///        (the agreed time the post stays live). Settlement must still fit before
    ///        `settleDeadline` even if the KOL accepts right at `postDeadline`.
    function createCampaign(
        address kol,
        address token,
        uint128 amount,
        uint16 deliveryBps,
        uint40 minLive,
        uint40 postDeadline,
        uint40 settleDeadline,
        bytes32 termsHash
    ) external nonReentrant returns (uint256 id) {
        if (kol == address(0)) revert ZeroAddress();
        if (!allowedToken[token]) revert TokenNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (deliveryBps > BPS) revert InvalidBps();
        if (postDeadline <= block.timestamp || uint256(settleDeadline) <= uint256(postDeadline) + minLive) {
            revert InvalidDeadlines();
        }

        _pull(IERC20(token), amount);

        id = nextId++;
        Campaign storage c = campaigns[id];
        c.sponsor = msg.sender;
        c.kol = kol;
        c.token = IERC20(token);
        c.amount = amount;
        c.deliveryBps = deliveryBps;
        c.feeBps = feeBps;
        c.feeRecipient = feeRecipient;
        c.minLive = minLive;
        c.postDeadline = postDeadline;
        c.settleDeadline = settleDeadline;
        c.status = Status.Funded;
        c.termsHash = termsHash;

        emit CampaignCreated(
            id, msg.sender, kol, token, amount, deliveryBps, c.feeBps, postDeadline, settleDeadline, termsHash
        );
        emit CampaignTerms(id, c.feeRecipient, minLive);
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
        c.acceptedAt = uint40(block.timestamp);
        emit CampaignAccepted(id);
    }

    // ----------------------------------------------------------- verifier

    /// @notice Mihenk posts the measured outcome. Reach can only count if delivered.
    ///         Not earlier than `minLive` seconds after the KOL accepted.
    function settle(uint256 id, bool delivered, bool reachHit, bytes32 resultHash) external {
        if (msg.sender != verifier) revert NotVerifier();
        Campaign storage c = campaigns[id];
        if (c.status != Status.Accepted) revert WrongStatus(c.status);
        if (block.timestamp < uint256(c.acceptedAt) + c.minLive) revert TooEarly();
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
        _pay(c.token, c.sponsor, c.amount);
    }

    /// @notice Withdraw payouts that could not be transferred earlier. Only to the caller.
    function claim(IERC20 token) external nonReentrant {
        uint256 amt = owed[address(token)][msg.sender];
        if (amt == 0) revert NothingToClaim();
        owed[address(token)][msg.sender] = 0;
        emit Claimed(address(token), msg.sender, amt);
        token.safeTransfer(msg.sender, amt);
    }

    // ------------------------------------------------------------- views

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return campaigns[id];
    }

    // ----------------------------------------------------------- internal

    function _pull(IERC20 t, uint128 amount) internal {
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
    }

    function _distribute(uint256 id, Campaign storage c) internal {
        c.status = Status.Closed;
        uint256 gross = c.kolPayout;
        uint256 fee = (gross * c.feeBps) / BPS;
        uint256 kolNet = gross - fee;
        uint256 refund = uint256(c.amount) - gross;

        emit CampaignClosed(id, kolNet, fee, refund);

        _pay(c.token, c.kol, kolNet);
        _pay(c.token, c.feeRecipient, fee);
        _pay(c.token, c.sponsor, refund);
    }

    /// @dev Transfers `amount`, or credits it to `to` if the token refuses the transfer,
    ///      so one refused recipient never blocks the others.
    function _pay(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!_tryTransfer(token, to, amount)) {
            owed[address(token)][to] += amount;
            emit PayoutDeferred(address(token), to, amount);
        }
    }

    function _tryTransfer(IERC20 token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return address(token).code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (uint256)) == 1;
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
