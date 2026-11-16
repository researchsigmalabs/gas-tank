// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title GasTank
/// @notice Holds the chain's native token and hands it to listed keeper EOAs.
///         The owner (the ops Safe) manages the list and can withdraw at any time.
contract GasTank {
    struct Recipient {
        uint256 amount; // fixed claim amount; 0 when not listed
        uint256 lastClaim; // timestamp of the last claim; 0 when never claimed
        uint256 position; // index in `_list` plus one; 0 when not listed
    }

    uint256 public constant CLAIM_PERIOD = 1 days;
    uint256 public constant CEILING_MULTIPLE = 2;
    uint256 public constant MIN_PARTIAL_DIVISOR = 10; // smallest partial payment = amount / 10
    uint256 public constant MAX_RECIPIENTS = 32;

    address public immutable owner;

    address[] private _list;
    mapping(address => Recipient) private _recipientOf;

    event Funded(address indexed from, uint256 amount);
    event RecipientSet(address indexed eoa, uint256 amount);
    event RecipientRemoved(address indexed eoa);
    event Distributed(uint256 share, uint256 count);
    event Withdrawn(address indexed to, uint256 amount);
    event Claimed(address indexed eoa, uint256 amount);

    error NotOwner();
    error NotRecipient();
    error InvalidRecipient();
    error InvalidAmount();
    error TooManyRecipients();
    error NothingToDistribute();
    error ClaimTooSoon(uint256 claimableAt);
    error BalanceAboveCeiling();
    error TankEmpty();
    error TransferFailed(address to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidRecipient();
        owner = owner_;
    }

    /// @notice Anyone can fund the tank.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Lists `eoa` with its claim amount, or changes the amount of a listed EOA.
    ///         An update keeps the EOA's last claim.
    function setRecipient(address eoa, uint256 amount) external onlyOwner {
        if (eoa == address(0) || eoa == address(this)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();

        Recipient storage recipient = _recipientOf[eoa];
        if (recipient.position == 0) {
            if (_list.length >= MAX_RECIPIENTS) revert TooManyRecipients();
            _list.push(eoa);
            recipient.position = _list.length;
        }
        recipient.amount = amount;

        emit RecipientSet(eoa, amount);
    }

    /// @notice Unlists `eoa` and erases its claim history.
    function removeRecipient(address eoa) external onlyOwner {
        uint256 position = _recipientOf[eoa].position;
        if (position == 0) revert NotRecipient();

        // Swap-and-pop: the last entry takes the removed one's slot, so the list stays dense.
        // When `eoa` is itself the last entry this rewrites it in place, then pops it.
        address last = _list[_list.length - 1];
        _list[position - 1] = last;
        _recipientOf[last].position = position;
        _list.pop();
        delete _recipientOf[eoa];

        emit RecipientRemoved(eoa);
    }

    /// @notice Splits the whole balance equally between the listed EOAs; the division
    ///         remainder stays in the tank. Ignores the balance ceiling and leaves every
    ///         EOA's last claim untouched. All or nothing: one failed transfer reverts it all.
    function distribute() external onlyOwner {
        uint256 count = _list.length;
        if (count == 0) revert NothingToDistribute();
        uint256 share = address(this).balance / count;
        if (share == 0) revert NothingToDistribute();

        emit Distributed(share, count);
        for (uint256 i; i < count; ++i) {
            _send(_list[i], share);
        }
    }

    /// @notice Sends `amount` of the native token to `to`.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();

        emit Withdrawn(to, amount);
        _send(to, amount);
    }

    /// @notice A listed EOA takes its fixed amount for itself, at most once per `CLAIM_PERIOD`
    ///         (the first claim is immediate) and only while its own balance is below
    ///         `CEILING_MULTIPLE` times that amount. When the tank holds less, it pays what is
    ///         left and the cooldown still starts, provided what is left reaches
    ///         `amount / MIN_PARTIAL_DIVISOR`; below that, or when the tank is empty, it reverts
    ///         and the cooldown does not start.
    function claim() external {
        Recipient storage recipient = _recipientOf[msg.sender];
        uint256 amount = recipient.amount;
        if (amount == 0) revert NotRecipient();
        uint256 lastClaim = recipient.lastClaim;
        // Validators can skew block.timestamp by seconds, immaterial against a 24 h period.
        // forge-lint: disable-next-line(block-timestamp)
        if (lastClaim != 0 && block.timestamp < lastClaim + CLAIM_PERIOD) {
            revert ClaimTooSoon(lastClaim + CLAIM_PERIOD);
        }
        if (msg.sender.balance >= CEILING_MULTIPLE * amount) revert BalanceAboveCeiling();
        uint256 available = address(this).balance;
        // The minimum stops a dust top-up (1 wei sent by anyone) from buying a keeper's 24 h.
        // `available == 0` still matters when the amount is under MIN_PARTIAL_DIVISOR wei.
        if (available == 0 || available < amount / MIN_PARTIAL_DIVISOR) revert TankEmpty();

        uint256 paid = amount < available ? amount : available;
        // Written before the transfer: a claim() re-entered from the payment sees it and is refused.
        recipient.lastClaim = block.timestamp;

        emit Claimed(msg.sender, paid);
        _send(msg.sender, paid);
    }

    function recipients() external view returns (address[] memory) {
        return _list;
    }

    /// @return The EOA's claim amount, 0 if not listed.
    function amountOf(address eoa) external view returns (uint256) {
        return _recipientOf[eoa].amount;
    }

    /// @return The timestamp of the EOA's last claim, 0 if never claimed.
    function lastClaimOf(address eoa) external view returns (uint256) {
        return _recipientOf[eoa].lastClaim;
    }

    /// @return The earliest timestamp of the EOA's next claim, 0 if never claimed.
    function claimableAt(address eoa) external view returns (uint256) {
        uint256 lastClaim = _recipientOf[eoa].lastClaim;
        return lastClaim == 0 ? 0 : lastClaim + CLAIM_PERIOD;
    }

    /// @dev Reverts the whole call if the transfer fails, including when `amount`
    ///      exceeds the tank's balance.
    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to);
    }
}
